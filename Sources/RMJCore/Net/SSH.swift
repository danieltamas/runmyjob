import Foundation

/// The one way RMJ reaches a destination: bound to the verified tailnet address, with every
/// source of surprise (proxies, multiplexing, prompts, new host keys) switched off.
public enum SSH {
    public enum Failure: Error, Equatable {
        case invalidAlias, invalidAddress, invalidControlDirectory
    }

    /// The arguments after `ssh` for running `command` (already one shell-ready string) on the destination.
    public static func arguments(address: String, alias: String, command: [String]) throws -> [String] {
        try options(address: address, alias: alias) + [alias, "--"] + command
    }

    /// The value of rsync's `-e`: the same ssh, same options.
    public static func rsyncShell(address: String, alias: String) throws -> String {
        (["ssh"] + (try options(address: address, alias: alias))).joined(separator: " ")
    }

    private static func options(address: String, alias: String) throws -> [String] {
        guard !alias.isEmpty, alias.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              !alias.hasPrefix("-") else { throw Failure.invalidAlias }
        guard TailnetAddress.isTailnet(address) else { throw Failure.invalidAddress }
        return ["-o", "HostName=\(address)", "-o", "HostKeyAlias=\(alias)", "-o", "ProxyCommand=none",
                "-o", "ProxyJump=none", "-o", "ControlMaster=auto", "-o", "ControlPath=\(try controlDirectory())/%C", "-o", "ControlPersist=10m",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5", "-o", "RequestTTY=no", "-o", "StrictHostKeyChecking=yes",
                "-o", "ServerAliveInterval=15"]
    }

    /// RMJ's own multiplexing sockets, in a directory only this user can enter: one authentication serves
    /// every ssh and rsync of the next ten minutes. The user's ssh config is not consulted for it, and the
    /// socket name hashes user, host and port, so a connection is only ever shared with the same target.
    static func controlDirectory() throws -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rmj/ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A link, another user's directory or a permissive one would expose the multiplexed sessions.
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              chmod(directory.path, 0o700) == 0 else { throw Failure.invalidControlDirectory }
        return directory.path
    }

    /// One argument for the remote shell: ssh joins the command words with spaces.
    public static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
