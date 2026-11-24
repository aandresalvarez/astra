import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

@Suite("Remote directory claim keys")
struct RemoteDirectoryClaimKeyTests {
    private func connection(
        host: String = "Release.Example.com", user: String = "deploy", port: Int = 22,
        path: String, alias: String = ""
    ) -> SSHConnection {
        SSHConnection(name: "box", host: host, user: user, port: port, remotePath: path, configAlias: alias)
    }

    @Test("Remote paths are normalized without contacting the host", arguments: [
        ("~/service", "~deploy/service"),
        ("service", "~deploy/service"),
        ("  ~/service/  ", "~deploy/service"),
        ("~/a/./b//c/../d", "~deploy/a/b/d"),
        ("", "~deploy"),
        ("~", "~deploy"),
        ("/srv//app/", "/srv/app"),
        ("/", "/"),
        ("/srv/../..", "/"),
        ("~/..", "/"),
        ("~other/project", "~other/project")
    ])
    func canonicalPaths(raw: String, expected: String) {
        #expect(RemoteDirectoryClaimKey.canonicalPath(raw, user: "deploy") == expected)
    }

    @Test("A connection without a user is rooted at the unnamed login home")
    func unnamedHome() {
        #expect(RemoteDirectoryClaimKey.canonicalPath("service", user: " ") == "~/service")
    }

    @Test("A configured alias is the machine, whatever the host fields say, because ssh is given only the alias")
    func aliasIsTheRouteSSHTakes() {
        // Two entries on one alias, one with stale host fields: one route.
        let current = RemoteDirectoryClaimKey.key(for: connection(host: "", path: "/srv/app", alias: "prod"))!
        let stale = RemoteDirectoryClaimKey.key(for: connection(host: "old.example.com", port: 2222, path: "/srv/app", alias: "prod"))!
        #expect(current == stale)
        #expect(RemoteDirectoryClaimKey.overlap(current, stale))
        // Through an alias the login user is the alias's, so `~` stays unnamed.
        #expect(RemoteDirectoryClaimKey.key(for: connection(path: "~/app", alias: "prod")) == "alias:prod ~/app")
    }

    @Test("Covering is the same machine and the same or a containing folder, never an uncertain one")
    func coveringFolders() {
        #expect(RemoteDirectoryClaimKey.covers("h:22 /srv", "h:22 /srv/app"))
        #expect(RemoteDirectoryClaimKey.covers("h:22 /srv/app", "h:22 /srv/app"))
        #expect(!RemoteDirectoryClaimKey.covers("h:22 /srv/app", "h:22 /srv"))
        #expect(!RemoteDirectoryClaimKey.covers("h:22 /srv/app", "other:22 /srv/app"))
        #expect(!RemoteDirectoryClaimKey.covers("h:22 ~/app", "h:22 /srv/app"))
    }

    @Test("The machine is the declared host and port, or the alias when one is set")
    func machineIdentity() {
        #expect(RemoteDirectoryClaimKey.key(for: connection(path: "~/service")) == "release.example.com:22 ~deploy/service")
        #expect(RemoteDirectoryClaimKey.key(for: connection(port: 2222, path: "/srv/app")) == "release.example.com:2222 /srv/app")
        #expect(RemoteDirectoryClaimKey.key(for: connection(host: "", path: "/srv/app", alias: "dev-box")) == "alias:dev-box /srv/app")
        #expect(RemoteDirectoryClaimKey.key(for: connection(host: " ", path: "/srv/app")) == nil)
        // A folder name with a space stays one key: the machine never has one.
        #expect(RemoteDirectoryClaimKey.key(for: connection(path: "/srv/my app")) == "release.example.com:22 /srv/my app")
    }

    @Test("Identical, containing and contained folders on one machine overlap")
    func overlappingFolders() {
        func key(_ path: String, user: String = "deploy", port: Int = 22, host: String = "h") -> String {
            RemoteDirectoryClaimKey.key(for: connection(host: host, user: user, port: port, path: path))!
        }
        #expect(RemoteDirectoryClaimKey.overlap(key("/srv/app"), key("/srv/app")))
        #expect(RemoteDirectoryClaimKey.overlap(key("/srv"), key("/srv/app")))
        #expect(RemoteDirectoryClaimKey.overlap(key("/srv/app/sub"), key("/srv/app")))
        #expect(RemoteDirectoryClaimKey.overlap(key("/"), key("/srv/app")))
        #expect(RemoteDirectoryClaimKey.overlap(key("~"), key("~/service")))
        // The same absolute folder is one folder whoever logs in.
        #expect(RemoteDirectoryClaimKey.overlap(key("/srv/app", user: "deploy"), key("/srv/app", user: "admin")))

        #expect(!RemoteDirectoryClaimKey.overlap(key("/srv/app"), key("/srv/application")))
        #expect(!RemoteDirectoryClaimKey.overlap(key("/srv/app"), key("/srv/other")))
        #expect(!RemoteDirectoryClaimKey.overlap(key("~/a"), key("~/b")))
        #expect(!RemoteDirectoryClaimKey.overlap(key("/srv/app"), key("/srv/app", host: "other")))
        #expect(!RemoteDirectoryClaimKey.overlap(key("/srv/app"), key("/srv/app", port: 2222)))
        // Two named users' homes are separate folders.
        #expect(!RemoteDirectoryClaimKey.overlap(key("~/a", user: "deploy"), key("~/a", user: "admin")))
    }

    @Test("Folders whose relation cannot be known locally are treated as overlapping")
    func unknownRelationsOverlap() {
        func key(_ path: String, user: String = "deploy") -> String {
            RemoteDirectoryClaimKey.key(for: connection(host: "h", user: user, path: path))!
        }
        // Where a home directory lives on the host is unknown.
        #expect(RemoteDirectoryClaimKey.overlap(key("~/app"), key("/srv/app")))
        // The unnamed login user may be the named one.
        #expect(RemoteDirectoryClaimKey.overlap(key("~/app", user: ""), key("~/other", user: "deploy")))
        // A path that climbs out of its home covers the machine.
        #expect(RemoteDirectoryClaimKey.overlap(key("~/../shared"), key("/srv/app")))
    }

    @Test("A waiting line names the folder and the machine")
    func displayName() {
        #expect(RemoteDirectoryClaimKey.displayName("release.example.com:22 ~deploy/service")
            == "~deploy/service on release.example.com:22")
    }
}
