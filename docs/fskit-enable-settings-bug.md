According to the logs collected at the time and a reverse-engineering analysis of `/usr/libexec/fskitd`, the message `did not find team ID` indicates that `fskitd` failed to obtain a Team ID from the **audit token of the XPC caller process**.

The caller in this case is neither `xntfs.app` nor `ntfs3g.appex`. Instead, it is one of the Apple extensions used by System Settings:

```text
com.apple.LoginItems-Settings.extension
com.apple.fskit.ModuleEnablement
```

The signatures of both Apple platform extensions currently show:

```text
TeamIdentifier=not set
```

As a result, `SecTaskCopyTeamIdentifier` returns no Team ID when called by `fskitd`.

### Team ID Retrieval Flow Observed from Reverse Engineering

When the user toggles a File System Extension switch in System Settings, the call chain is roughly:

```text
System Settings
  -> LoginItems.appex / FSKitModuleManagement.appex
  -> /usr/libexec/fskitd
```

After receiving the XPC connection, `fskitd` logs messages similar to:

```text
Incomming connection, entitled 0
```

Reverse engineering of `-[fskitdXPCServer getTeamIDForToken:]` shows the following key logic:

```text
SecTaskCreateWithAuditToken(NULL, auditToken)
SecTaskCopyTeamIdentifier(task, &error)
```

If `SecTaskCopyTeamIdentifier` returns `NULL`, `fskitd` logs:

```text
Received error '(null)', errno 2, retrieving team ID
-[fskitdXPCServer getTeamIDForToken:] did not find team ID
```

and ultimately returns an empty string as the Team ID.

Importantly, this Team ID is derived from the audit token associated with the incoming XPC connection—that is, the System Settings-related process calling `fskitd`. It is **not** obtained by inspecting the target FSKit module's bundle path or code signature.

### Why the Team ID Is Empty

Verification on the affected machine showed:

```text
/System/Library/ExtensionKit/Extensions/LoginItems.appex
Identifier=com.apple.LoginItems-Settings.extension
TeamIdentifier=not set

/System/Library/ExtensionKit/Extensions/FSKitModuleManagement.appex
Identifier=com.apple.fskit.ModuleEnablement
TeamIdentifier=not set
```

Meanwhile, the xntfs application and extension are correctly signed:

```text
/Applications/xntfs.app
Identifier=com.huanchuan.xntfs
TeamIdentifier=529LJDH392

/Applications/xntfs.app/Contents/Extensions/ntfs3g.appex
Identifier=com.huanchuan.xntfs.ntfs3g
TeamIdentifier=529LJDH392
```

Therefore, this error is **not** caused by a missing local developer certificate, nor by xntfs lacking a valid Team ID in its code signature.

The issue appears to stem from the enablement path in System Settings using Apple platform extensions as the XPC caller, while those extensions do not expose a conventional third-party-style `TeamIdentifier`.

### Why This Causes the Toggle Operation to Fail

The logs also contained:

```text
LoginItems: Failed to enabled FSExtension: Error Domain=NSPOSIXErrorDomain Code=1
```

and did **not** contain the message normally seen on the successful path:

```text
Call fskit_agent to set enabled state of identifier (...) to (...)
```

Reverse engineering of `setEnabledStateForIdentifier:newState:replyHandler:` confirmed that `fskitd` performs connection authorization checks before attempting to write the enabled state.

For the System Settings connection:

```text
Incomming connection, entitled 0
```

indicates that the caller lacks private entitlements such as:

```text
com.apple.private.LiveFS.connection
```

At the same time, the restricted authorization path attempts to retrieve a Team ID from the caller's audit token, but the Apple caller yields an empty Team ID.

As a result, the request is rejected during `fskitd`'s preliminary authorization checks and returns:

```text
EPERM
NSPOSIXErrorDomain Code=1
```

The request never reaches the stage where `fskit_agent` performs the actual enable-state update, which explains why the extension toggle operation fails.
