# Privacy Policy

Last updated: October 30, 2026

xntfs is an open-source macOS utility for mounting NTFS volumes with Apple's FSKit file-system extension model and the ntfs-3g engine.

This policy explains what the app and its file-system extension do with data. xntfs mounts and accesses files locally on your Mac. It does not run ads or track you. Optional problem reports are shared only after you review them and explicitly choose to send them.

## Data Collection

The app does not include analytics, advertising or tracking SDKs, user accounts, or automatic remote telemetry. A problem report may include information you enter, such as your description and an optional reply email, plus an optional diagnostic snapshot. These are used to investigate your report and reply to you, not for advertising or tracking.

## Local File and Disk Access

xntfs needs access to NTFS volumes in order to provide file-system functionality.

When an NTFS drive or disk image is mounted through the xntfs FSKit extension, the extension may read and write file-system data on that volume, including file contents, file names, directory entries, file metadata, and NTFS file-system structures. This processing happens locally on your Mac as part of normal file-system operation.

xntfs does not upload the contents of your drives, file names, directory listings, or disk images.

## Disk Images

If you choose a disk image in the app, macOS grants access to that selected file. Depending on the macOS version and image format, xntfs mounts it directly or offers system tools or a copyable command. The image file is not uploaded.

## Diagnostics

xntfs includes a diagnostics view to help explain whether the FSKit extension is installed, enabled, or registered more than once.

Diagnostics may show local status information such as:

- whether the extension is installed
- whether the extension is enabled
- local extension registration paths
- suggested Terminal commands for troubleshooting

This information is shown locally in the app. xntfs does not send it to us automatically.

The app and extension also keep a bounded local history of mount-related operations. It contains timestamps, app versions, temporary process/attempt identifiers, BSD device numbers, access modes and error domains/codes. It does not record file contents, volume names, full paths, disk serial numbers, or arbitrary error descriptions. The shared history is limited to 400 events and 512 KiB; entries older than seven days are removed when the recorder next reads or writes the history. If shared storage is unavailable, only limited in-process evidence may be available.

## Optional Problem Reports

You can describe a problem, optionally enter a reply email, and include a diagnostic snapshot. A snapshot adds macOS version/build, hardware model and processor architecture, app version, extension registration/enablement status, read-only preferences, technical disk/mount state and the recent local history. Registration paths are replaced by location categories. The app does not collect screenshots, full system logs, crash dumps, file listings, or disk images for this report.

The complete report is previewed before export or sending. Review your own text for private information. Export saves a JSON file locally and does not upload anything. When an online receiver is configured, sending requires a separate confirmation and an explicit click. Without a receiver, only export is available. There is no automatic retry or background upload queue.

Online reports use Sentry's ingestion service; the receiver is displayed before you send. That service can see the network IP address used to connect even though xntfs does not add it to the report. Submitted reports and optional contact details are accessible to the project's support maintainer and the receiving service, subject to its retention settings and [Sentry's privacy policy](https://sentry.io/privacy/). For deletion requests, contact us through the repository and provide the report ID, not a public copy of private report contents. Exported copies remain wherever you choose to save or share them.

## Clipboard

Some operations are shown as copyable Terminal commands because the macOS sandbox prevents the app from running those commands directly. When you click a Copy button, xntfs writes that command to the macOS clipboard.

## Settings

xntfs stores simple local preferences, such as whether manual mounts should default to read-only mode. These preferences are stored locally using macOS user defaults.

## Network Access

xntfs does not need a network connection for mounting or file access. Network access is used for optional reports only when you explicitly send one.

If you visit the project website, GitHub repository, or support pages, those services may process data according to their own privacy policies.

## Third-Party Code

xntfs uses ntfs-3g as its NTFS engine. ntfs-3g runs locally as part of the file-system implementation included with the app extension.

## Crash Reports and System Logs

macOS may create crash reports or system logs according to your system settings. xntfs does not automatically receive or upload those reports. If you choose to share logs or diagnostics in a GitHub issue or support request, please review them first and remove anything you do not want to share.

## Children

xntfs is a general-purpose utility and does not knowingly collect data from children.

## Open Source

The source code is available at:

https://github.com/HuanchuanTech/xntfs
## Changes

We may update this policy when the app changes. The latest version will be published with the app and in the project repository.

## Contact

For questions or privacy-related requests, please use the project repository:

https://github.com/HuanchuanTech/xntfs
