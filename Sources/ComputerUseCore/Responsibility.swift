import Darwin
import Foundation

// Who gets the macOS permissions. macOS grants Accessibility and Screen Recording to the "responsible" process: by
// default the app that started us (Terminal, iTerm, Claude, Cursor…), which would then let every program it runs
// control the Mac. So the MCP server starts again as its own responsible process (posix_spawn with the "disclaim"
// attribute, the technique used by LLDB and Chromium): permissions go to "Mac Computer Use MCP" alone.
// The attribute is private API, looked up at run time; when it is missing we simply run without it.
// Only from the app bundle: that is where the permissions are granted. A bare binary run from a source folder keeps
// its terminal's responsibility, otherwise macOS would ask it for access to a protected folder (Documents, Desktop…)
// before it could even load itself.

public enum Responsibility {
    static let marker = "MAC_COMPUTER_USE_MCP_DISCLAIMED"
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
    private static let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)

    /// Restarts this program as its own responsible process and exits with its status. Returns (to run normally) when
    /// already disclaimed, outside an app bundle, when MAC_COMPUTER_USE_MCP_NO_DISCLAIM is set, or when the system does not offer it.
    public static func disclaimIfNeeded() {
        guard getenv(marker) == nil, getenv("MAC_COMPUTER_USE_MCP_NO_DISCLAIM") == nil,
              let symbol = dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim"), let path = executablePath(),
              path.contains(".app/Contents/MacOS/") else { return }
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return }
        defer { posix_spawnattr_destroy(&attributes) }
        guard setDisclaim(&attributes, 1) == 0 else { return }
        setenv(marker, "1", 1)
        let arguments = [path] + CommandLine.arguments.dropFirst()
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        // stdin, stdout and stderr are inherited: the child talks to the MCP client directly.
        guard posix_spawn(&pid, path, nil, &attributes, &argv, environ) == 0 else { unsetenv(marker); return }
        child = pid
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig) { kill(Responsibility.child, $0) } }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        exit(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
    static var child: pid_t = 0

    /// The process macOS holds responsible for this one (itself after disclaimIfNeeded), nil when unknown.
    public static func responsiblePid() -> pid_t? {
        guard let symbol = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid") else { return nil }
        let pid = unsafeBitCast(symbol, to: ResponsibleFor.self)(getpid())
        return pid > 0 ? pid : nil
    }

    /// The real path of this executable (symbolic links resolved), so the restarted process lives in its app bundle.
    public static func executablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}
