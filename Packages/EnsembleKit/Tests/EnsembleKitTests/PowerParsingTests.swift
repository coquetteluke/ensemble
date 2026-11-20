import Foundation
import Testing
@testable import EnsembleKit

@Suite struct PowerParsingTests {
    // MARK: pmset

    @Test func sleepDisabledLineUsesTabs() {
        let on = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
        """
        #expect(PowerParsing.sleepDisabled(fromPMSet: on) == true)
        #expect(PowerParsing.sleepDisabled(fromPMSet: " SleepDisabled\t\t0\n") == false)
        #expect(PowerParsing.sleepDisabled(fromPMSet: " SleepDisabled  1\n") == true)
        #expect(PowerParsing.sleepDisabled(fromPMSet: "Currently in use:\n sleep 1\n") == nil)
        // "Sleep On Power Button 1" is not SleepDisabled.
        #expect(PowerParsing.sleepDisabled(fromPMSet: " Sleep On Power Button 1\n") == nil)
    }

    @Test func batteryAndLid() {
        #expect(PowerParsing.onBattery(fromPMSetPS: "Now drawing from 'Battery Power'\n -InternalBattery-0"))
        #expect(!PowerParsing.onBattery(fromPMSetPS: "Now drawing from 'AC Power'\n -InternalBattery-0"))
        #expect(PowerParsing.hasLid(fromIoreg: "  \"AppleClamshellState\" = No\n"))
        #expect(!PowerParsing.hasLid(fromIoreg: ""))
    }

    // MARK: sudo -l

    @Test func lidlockRuleIsAccepted() {
        let listing = """
        Matching Defaults entries for sam on Sams-MacBook-Air:
            env_reset, env_keep+=BLOCKSIZE, env_keep+="COLORFGBG COLORTERM",
            lecture_file=/etc/sudo_lecture, !log_allowed

        User sam may run the following commands on Sams-MacBook-Air:
            (ALL) ALL
            (root) NOPASSWD: /usr/bin/pmset disablesleep *
        """
        #expect(PowerParsing.sudoListingAllowsPMSet(listing))
    }

    @Test func adminRuleWithPasswordIsNotEnough() {
        let listing = """
        User sam may run the following commands on mac:
            (ALL) ALL
            (root) NOPASSWD: /usr/bin/true
        """
        #expect(!PowerParsing.sudoListingAllowsPMSet(listing))
    }

    @Test func otherRuleShapes() {
        func allows(_ entries: String) -> Bool {
            PowerParsing.sudoListingAllowsPMSet("User sam may run the following commands on mac:\n" + entries)
        }
        #expect(allows("    (ALL) NOPASSWD: ALL"))
        #expect(allows("    (ALL : ALL) NOPASSWD: /usr/bin/pmset"))
        #expect(allows("    (root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"))
        #expect(allows("    (root) NOPASSWD: SETENV: /usr/bin/pmset disablesleep *"))
        #expect(!allows("    (root) NOPASSWD: /usr/bin/pmset disablesleep 1"))
        #expect(!allows("    (root) PASSWD: /usr/bin/pmset disablesleep *"))
        #expect(!allows("    (root) NOPASSWD: /bin/ls, PASSWD: /usr/bin/pmset disablesleep *"))
        #expect(!allows("    (nobody) NOPASSWD: /usr/bin/pmset disablesleep *"))
        // A long entry wrapped onto the next line.
        #expect(allows("    (root) NOPASSWD: /bin/ls, /usr/bin/true,\n        /usr/bin/pmset disablesleep *"))
        #expect(!PowerParsing.sudoListingAllowsPMSet("sudo: a password is required"))
    }

    @Test func passwordRequiredMessage() {
        #expect(PowerParsing.sudoWantedPassword("sudo: a password is required\n"))
        #expect(!PowerParsing.sudoWantedPassword("pmset: invalid argument"))
    }

    // MARK: Setup script

    @Test func userNamesAreValidated() {
        #expect(PowerSudoers.isValidUserName("alexsmith"))
        #expect(PowerSudoers.isValidUserName("first.last-2"))
        #expect(!PowerSudoers.isValidUserName(""))
        #expect(!PowerSudoers.isValidUserName("alex'; rm -rf /"))
        #expect(!PowerSudoers.isValidUserName("alex smith"))
        #expect(!PowerSudoers.isValidUserName("-alex"))
        #expect(PowerSudoers.installScript(user: "bad name") == nil)
        #expect(PowerSudoers.appleScript(user: "a\"b") == nil)
    }

    @Test func ruleMatchesTheLidlockRule() {
        #expect(PowerSudoers.ruleLine(user: "sam") == "sam ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0")
    }

    @Test func installScriptChecksBeforeInstalling() throws {
        let script = try #require(PowerSudoers.installScript(user: "sam"))
        let lines = script.split(separator: "\n").map(String.init)
        func index(_ needle: String) throws -> Int {
            try #require(lines.firstIndex { $0.contains(needle) }, "missing \(needle)")
        }
        let write = try index("printf")
        let check = try index("visudo -cf")
        let owner = try index("chown root:wheel")
        let mode = try index("chmod 0440")
        let move = try index("/bin/mv -f")
        #expect(write < check && check < owner && owner < mode && mode < move)
        #expect(lines[0] == "set -e")
        #expect(script.contains("'sam ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0'"))
        #expect(script.contains("'/private/etc/sudoers.d/ensemble-pmset'"))
        // The temporary file has a dot in its name, so sudo never reads it.
        #expect(script.contains("/private/etc/sudoers.d/.ensemble-pmset.XXXXXX"))
        #expect(lines.last?.contains("visudo -c") == true)
    }

    @Test func appleScriptEscapesTheShellScript() throws {
        #expect(PowerSudoers.appleScriptQuoted(#"a "b" \n"#) == #""a \"b\" \\n""#)
        let source = try #require(PowerSudoers.appleScript(user: "sam"))
        #expect(source.hasPrefix("do shell script \"set -e\n"))
        #expect(source.hasSuffix("with administrator privileges"))
        #expect(source.contains(#"printf '%s\\n'"#))
        #expect(source.contains(#"trap '/bin/rm -f \"$tmp\"' EXIT"#))
    }

    @Test func holderKeysRoundTrip() {
        let room = UUID()
        #expect(PowerHolderID(key: PowerHolderID.room(room).key) == .room(room))
        #expect(PowerHolderID(key: "session:ses_1:x") == .session("ses_1:x"))
        #expect(PowerHolderID(key: "session:") == nil)
        #expect(PowerHolderID(key: "other:1") == nil)
    }
}
