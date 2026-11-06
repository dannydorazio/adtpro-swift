# Archived: the Java host

This is the original ADTPro host (server), written in Java, kept for reference. It is no longer built or used. The Swift host in `Sources/` and `App/` replaces it and speaks the same protocol to the unchanged Apple clients in `client/`.

| Path | Contents |
|---|---|
| `src/org/adtpro` | The Java host: `CommsThread.java` (the wire protocol), transports, Swing GUI, nibble analysis |
| `build/` | The Ant build (`build.xml`), launch scripts, macOS DMG packaging, and the AppleCommander and jSSC jars it depended on |
| `doc/` | The adtpro.com website (Maven site, APT format), including the protocol references in `doc/src/site/apt/protocol*.apt` and the virtual drive pages `vdrive*.apt` / `vsdrive.apt` / `vedrive.apt` |
| `.classpath`, `.project` | Eclipse project files |

The Ant build expected the client sources at `src/client` and its base disks and libraries in `build/`. Those now live in `client/`, `client/disks` and `client/lib`, so `build.xml` would need its paths adjusted to run again.

The Swift port fixes several defects in this code; the top-level README lists them under "Differences from the Java host".
