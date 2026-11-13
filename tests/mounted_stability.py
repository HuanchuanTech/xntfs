#!/usr/bin/env python3
"""Finite host I/O and RSS observation for run_macos27_images.sh device mode.

The caller verifies mounted type/source/mode. This program independently binds
the device to the runner's owned image. It never attaches, unmounts or kills.
"""
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
WORKERS, WARMUP, ROUNDS = 4, 2, 32
SIZE, CHUNK, SMALL = 512 * 1024, 64 * 1024, 8
DIRECTORY = 'xntfs-release-stability'
EXTENSION = '/Applications/xntfs.app/Contents/Extensions/ntfs3g.appex/Contents/MacOS/ntfs3g'


class CheckFailure(RuntimeError):
    pass


def need(condition, message):
    if not condition:
        raise CheckFailure(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def body(round_id, worker):
    pattern = hashlib.sha256(f'xntfs-stability-v1:{round_id}:{worker}'.encode()).digest()
    return pattern * (SIZE // len(pattern))


class Metrics:
    def __init__(self):
        self.values = {}

    def call(self, label, function, *args):
        start = time.monotonic()
        try:
            return function(*args)
        finally:
            self.values.setdefault(label, []).append(time.monotonic() - start)

    def merge(self, other):
        for key, values in other.values.items():
            self.values.setdefault(key, []).extend(values)

    def summary(self):
        result = {}
        for key, values in self.values.items():
            ordered = sorted(values)
            result[key] = {'calls': len(values), 'total_seconds': sum(values),
                           'p50_seconds': statistics.median(values),
                           'p95_seconds': ordered[(len(ordered) - 1) * 95 // 100],
                           'max_seconds': ordered[-1]}
        return result


def write_file(path, data, metrics, sync=False):
    fd = metrics.call('open_write', os.open, path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        done, calls = 0, 0
        while done < len(data):
            need(calls < 64, 'bounded short-write retries')
            count = metrics.call('write', os.write, fd, memoryview(data)[done:done + CHUNK])
            need(count > 0, 'write made no progress')
            done += count
            calls += 1
        if sync:
            metrics.call('fsync', os.fsync, fd)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass  # Preserve the first I/O error; normal close errors propagate below.
        raise
    else:
        metrics.call('close_write', os.close, fd)
    return done


def verify_file(path, expected, size, metrics):
    fd = metrics.call('open_read', os.open, path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fcntl.fcntl(fd, fcntl.F_NOCACHE, 1)
        need(metrics.call('fstat', os.fstat, fd).st_size == size, f'length mismatch: {path.name}')
        found, count = hashlib.sha256(), 0
        for _ in range(65):
            chunk = metrics.call('read', os.read, fd, CHUNK)
            if not chunk:
                break
            count += len(chunk)
            need(count <= size, f'read exceeds expected size: {path.name}')
            found.update(chunk)
        else:
            raise CheckFailure('bounded short-read retries')
        need(count == size and found.hexdigest() == expected, f'content mismatch: {path.name}')
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass  # Preserve the first I/O error; normal close errors propagate below.
        raise
    else:
        metrics.call('close_read', os.close, fd)
    return count


def identity(mount, output):
    image = Path(os.environ['XNTFS_TEST_IMAGE']).resolve(strict=True)
    device = '/dev/' + os.environ['XNTFS_TEST_DEVICE']
    need(output.is_relative_to(ROOT / '_tmp') and output.name.startswith('macos27-image-tests.'), 'owned report directory')
    need(image == output / 'attached.img' and image.is_file(), 'owned runner image')
    need(mount.is_relative_to(Path('/Volumes')), 'mounted path')
    query = subprocess.run(['/usr/bin/hdiutil', 'info', '-plist'], capture_output=True, check=True, timeout=20)
    matches = [entry for entry in plistlib.loads(query.stdout).get('images', [])
               if Path(entry.get('image-path', '/')).resolve() == image]
    need(len(matches) == 1, 'unique attached image')
    devices = [entry.get('dev-entry') for entry in matches[0].get('system-entities', [])]
    need(device in devices and device.endswith('s1') and device[:-2] in devices, 'attached device identity')
    return {'image': str(image), 'partition': device, 'mount': str(mount)}


def extension_processes():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,rss=,lstart=,comm='],
                            capture_output=True, text=True, check=True, timeout=5)
    processes = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8 and fields[7] == EXTENSION:
            processes.append({'pid': int(fields[0]), 'rss_bytes': int(fields[1]) * 1024,
                              'started': ' '.join(fields[2:7]), 'executable': fields[7]})
    return processes


def device_owner(text, candidates, device):
    allowed = {device, device.replace('/dev/disk', '/dev/rdisk', 1)}
    matches, pid, kind = set(), None, None
    for line in text.splitlines():
        if line.startswith('p'):
            pid, kind = int(line[1:]), None
        elif line.startswith('f'):
            kind = None
        elif line.startswith('t'):
            kind = line[1:]
        elif line.startswith('n') and kind in ('CHR', 'BLK') and line[1:] in allowed:
            matches.add(pid)
    owners = [row for row in candidates if row['pid'] in matches]
    need(len(owners) == 1, f'unique extension with this device open required; matching pids={sorted(matches)}')
    return owners[0]


def resolve_owner(device, output, label):
    candidates = extension_processes()
    need(0 < len(candidates) <= 16, 'bounded extension candidates')
    command = ['/usr/sbin/lsof', '-b', '-nP', '-a', '-p',
               ','.join(str(row['pid']) for row in candidates), '-Fpcftn']
    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    (output / ('stability-owner-' + label + '.log')).write_text(result.stdout + result.stderr)
    need(result.returncode == 0, f'device descriptor observation failed: {result.returncode}')
    owner = device_owner(result.stdout, candidates, device)
    (output / ('stability-owner-' + label + '.json')).write_text(json.dumps(
        {'device': device, 'owner': owner, 'candidates': candidates, 'command': command}, indent=2) + '\n')
    return owner


class Observer:
    def __init__(self, owner):
        self.owner = owner
        self.phase = 'before'
        self.samples, self.errors = [], []
        self.lock, self.stopped = threading.Lock(), threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def sample(self):
        phase, start = self.phase, time.time()
        try:
            processes = extension_processes()
            selected = [row for row in processes if row['pid'] == self.owner['pid'] and row['started'] == self.owner['started']]
            need(len(selected) == 1, 'selected device-owning extension disappeared or changed identity')
            with self.lock:
                need(len(self.samples) < 1024, 'bounded RSS samples')
                self.samples.append({'epoch': start, 'phase': phase, **selected[0],
                                     'other_instances': [row for row in processes if row['pid'] != self.owner['pid']]})
        except Exception as error:
            with self.lock:
                self.errors.append(str(error))

    def run(self):
        while not self.stopped.wait(0.25):
            self.sample()
            if len(self.samples) + len(self.errors) >= 1024:
                break

    def mark(self, phase):
        self.phase = phase
        self.sample()

    def finish(self):
        self.stopped.set()
        if self.thread.ident is not None:
            self.thread.join()

    def report(self):
        phases = {}
        for phase in sorted({row['phase'] for row in self.samples}):
            values = [row['rss_bytes'] for row in self.samples if row['phase'] == phase]
            phases[phase] = {'samples': len(values), 'first': values[0], 'last': values[-1],
                             'minimum': min(values), 'maximum_observed': max(values),
                             'median': statistics.median(values)}
        return {'samples': self.samples, 'errors': self.errors, 'phases': phases,
                'scope': 'ps resident memory samples; not allocator live bytes or a general RSS bound'}


def worker(directory, round_id, worker_id, deadline):
    need(time.monotonic() < deadline, '120-second admission deadline; no cancellation of pending I/O')
    metrics, started = Metrics(), time.monotonic()
    data = body(round_id, worker_id)
    pending, final = directory / 'pending.bin', directory / 'file.bin'
    written = write_file(pending, data, metrics, sync=True)
    metrics.call('rename', os.replace, pending, final)
    read = verify_file(final, digest(data), len(data), metrics)
    names = {'file.bin'}
    for index in range(SMALL):
        data = hashlib.sha256(f'{round_id}:{worker_id}:{index}'.encode()).digest() * 4
        temporary, renamed = directory / f'small-{index}.tmp', directory / f'small-{index}.bin'
        write_file(temporary, data, metrics)
        metrics.call('rename', os.rename, temporary, renamed)
        verify_file(renamed, digest(data), len(data), metrics)
        names.add(renamed.name)
    need(set(metrics.call('list', os.listdir, directory)) == names, 'enumerated names match exactly')
    for name in sorted(names - {'file.bin'}):
        metrics.call('unlink', os.unlink, directory / name)
    row = {'round': round_id, 'worker': worker_id, 'seconds': time.monotonic() - started,
           'large_bytes_written': written, 'large_bytes_read': read, 'small_files_verified': SMALL}
    return row, metrics


def expected_manifest():
    last = WARMUP + ROUNDS - 1
    return {'version': 1, 'workers': WORKERS, 'last_round': last, 'bytes_per_file': SIZE,
            'hashes': {f'worker-{i}/file.bin': digest(body(last, i)) for i in range(WORKERS)}}


def verify_final(directory, metrics):
    manifest = expected_manifest()
    expected = (json.dumps(manifest, sort_keys=True) + '\n').encode()
    verify_file(directory / 'manifest.json', digest(expected), len(expected), metrics)
    need(set(os.listdir(directory)) == {'manifest.json', *[f'worker-{i}' for i in range(WORKERS)]}, 'final root names')
    for name, value in manifest['hashes'].items():
        path = directory / name
        need(os.listdir(path.parent) == ['file.bin'], 'no temporary files retained')
        verify_file(path, value, SIZE, metrics)
    return manifest


def run(mode, mount, output):
    report = {'mode': mode, 'identity': identity(mount, output), 'result': 'RUNNING', 'completed': []}
    directory, metrics, observer = mount / DIRECTORY, Metrics(), None
    started = time.monotonic()
    def event(phase, **values):
        row = {'phase': phase, 'epoch': time.time(), **values}
        with (output / 'stability-events.jsonl').open('a') as stream:
            stream.write(json.dumps(row) + '\n')
        print('STABILITY ' + json.dumps(row), flush=True)
    try:
        if mode == 'rw':
            directory.mkdir()  # Existing or foreign state must fail, never overwrite.
            for index in range(WORKERS):
                (directory / f'worker-{index}').mkdir()
            deadline = time.monotonic() + 120
            owner = resolve_owner(report['identity']['partition'], output, 'before')
            report['device_owner'] = owner
            observer = Observer(owner)
            observer.mark('before')
            observer.thread.start()
            with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
                for round_id in range(WARMUP + ROUNDS):
                    phase = 'warmup' if round_id < WARMUP else 'load'
                    if round_id in (0, WARMUP):
                        observer.mark(phase)
                    futures = [pool.submit(worker, directory / f'worker-{i}', round_id, i, deadline) for i in range(WORKERS)]
                    for future in futures:
                        row, measured = future.result()
                        report['completed'].append(row)
                        metrics.merge(measured)
                    event(phase, round=round_id, completed=len(report['completed']))
            need(len(report['completed']) == WORKERS * (WARMUP + ROUNDS), 'all work units completed')
            manifest = (json.dumps(expected_manifest(), sort_keys=True) + '\n').encode()
            write_file(directory / 'manifest.json', manifest, metrics, sync=True)
            report['final_manifest'] = verify_final(directory, metrics)
            observer.mark('idle')
            event('idle-start')
            time.sleep(10)
            observer.mark('idle')
            observer.finish()
            observation = observer.report()
            need(not observation['errors'], f'RSS observation errors: {len(observation["errors"])}; see report')
            identities = {(s['pid'], s['started']) for s in observation['samples']}
            need(len(identities) == 1, 'extension identity changed during mounted workload')
            need(all(phase in observation['phases'] for phase in ('before', 'warmup', 'load', 'idle')), 'all RSS phases observed')
            after = resolve_owner(report['identity']['partition'], output, 'after')
            need((after['pid'], after['started']) == (owner['pid'], owner['started']), 'device owner changed')
            report['memory'] = observation
            event('idle-end')
        else:
            report['final_manifest'] = verify_final(directory, metrics)
            event('remount-verified', files=WORKERS)
        report['result'] = 'PASS_FINITE_MOUNTED_STABILITY' if mode == 'rw' else 'PASS_READ_ONLY_REMOUNT_CONTENTS'
    except Exception as error:
        report.update(result='FAIL', error=repr(error))
        raise
    finally:
        if observer:
            observer.finish()
            report['memory'] = observer.report()
        report.update(elapsed_seconds=time.monotonic() - started, operations=metrics.summary())
        (output / ('stability-' + mode + '.json')).write_text(json.dumps(report, indent=2) + '\n')
        event('result', mode=mode, result=report['result'])


def self_test():
    from unittest.mock import patch

    with tempfile.TemporaryDirectory(prefix='xntfs-stability-oracle-', dir='/tmp') as directory:
        path, expected = Path(directory) / 'file', b'known independent bytes\n'
        path.write_bytes(expected)
        verify_file(path, digest(expected), len(expected), Metrics())
        rejected = 0
        for data in (b'X' + expected[1:], expected[:-1], expected + b'X'):
            path.write_bytes(data)
            try:
                verify_file(path, digest(expected), len(expected), Metrics())
            except CheckFailure:
                rejected += 1
        need(rejected == 3, 'content, truncation and extra-byte negative controls')
        real_close = os.close
        for operation in ('write', 'read'):
            for fail_io in (False, True):
                target = Path(directory) / f'{operation}-{fail_io}'
                if operation == 'read':
                    target.write_bytes(expected)
                first, closing = OSError('first I/O failure'), OSError('close failure')

                def failing_close(fd):
                    real_close(fd)
                    raise closing

                with patch.object(os, 'close', side_effect=failing_close), patch.object(
                        os, operation, wraps=getattr(os, operation),
                        side_effect=first if fail_io else None):
                    try:
                        if operation == 'write':
                            write_file(target, expected, Metrics())
                        else:
                            verify_file(target, digest(expected), len(expected), Metrics())
                    except OSError as error:
                        need(error is (first if fail_io else closing), 'first I/O or standalone close error preserved')
                    else:
                        raise CheckFailure('close fault was not reported')
    candidates = [{'pid': 10}, {'pid': 20}]
    valid = 'p10\nf3\ntCHR\nn/dev/null\np20\nf3\ntBLK\nn/dev/disk99s1\n'
    need(device_owner(valid, candidates, '/dev/disk99s1')['pid'] == 20, 'device owner differs from idle instance')
    rejected = 0
    for text in (valid.replace('/dev/disk99s1', '/dev/disk98s1'),
                 valid.replace('/dev/null', '/dev/disk99s1'), valid.replace('tBLK', 'tREG')):
        try:
            device_owner(text, candidates, '/dev/disk99s1')
        except CheckFailure:
            rejected += 1
    need(rejected == 3, 'missing, ambiguous and regular-file owner controls')
    print('PASS stability oracle and device owner selection: 2 valid, 6 negative controls, 4 I/O/close fault cases; no FSKit acceptance')


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--self-test']:
            self_test()
        else:
            need(len(sys.argv) == 4 and sys.argv[1] in ('rw', 'remount-ro'), 'mode mount output required')
            run(sys.argv[1], Path(sys.argv[2]).resolve(strict=True), Path(sys.argv[3]).resolve(strict=True))
    except Exception as error:
        print('STABILITY FAILED: ' + repr(error), file=sys.stderr, flush=True)
        sys.exit(1)
