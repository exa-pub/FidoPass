import Foundation
import ArgumentParser
import FidoPassCore
#if canImport(AppKit)
import AppKit
#endif
import Darwin

struct FidoPass: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "fidopass",
        abstract: "Генератор паролей через FIDO2 hmac-secret (resident, без локального хранилища)",
        subcommands: [Enroll.self, Gen.self, List.self, Devices.self]
    )
}

extension FidoPass {
    struct Enroll: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Создать resident credential на ключе. Для portable используйте --rp fidopass.portable и затем импорт (см. README)")
        @Option(name: .shortAndLong, help: "Идентификатор учётки") var account: String
        @Option(name: .customLong("rp"), help: "RP ID") var rpId: String = "fidopass.local"
        @Option(name: .customLong("user"), help: "Имя пользователя (отображение)") var userName: String = NSUserName()
        @Flag(name: .customLong("uv"), help: "Требовать UV/PIN") var requireUV: Bool = true
        @Option(name: .customLong("device"), help: "Путь устройства (см. devices)") var devicePath: String?
        mutating func run() throws {
            let core = FidoPassCore.shared
            let acc = try core.enroll(accountId: account, rpId: rpId, userName: userName, requireUV: requireUV, residentKey: true, devicePath: devicePath) { readPIN() }
            print("OK. account=\(acc.id) device=\(acc.devicePath ?? "?")")
        }
    }

    struct Gen: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Сгенерировать пароль для метки")
        @Option(name: .shortAndLong) var account: String
        @Option(name: .shortAndLong) var label: String
        @Option(name: .customLong("device"), help: "Путь устройства (если несколько)") var devicePath: String
        @Flag(name: .customLong("uv"), help: "Требовать UV/PIN") var requireUV: Bool = true
        @Flag(name: .customLong("copy")) var copy: Bool = false
        mutating func run() throws {
            let core = FidoPassCore.shared
            let pin = readPIN()
            let accounts = try core.enumerateAccounts(devicePath: devicePath, pin: pin)
            guard let acc = accounts.first(where: { $0.id == account }) else {
                throw ValidationError("Аккаунт не найден на устройстве")
            }
            let pwd = try core.generatePassword(account: acc, label: label, requireUV: requireUV) { pin }
            if copy {
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pwd, forType: .string)
                print("Скопировано в буфер обмена")
                #else
                print(pwd)
                #endif
            } else { print(pwd) }
        }
    }

    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Перечислить аккаунты на устройстве")
        @Option(name: .customLong("device"), help: "Путь устройства") var devicePath: String
        mutating func run() throws {
            let core = FidoPassCore.shared
            let pin = readPIN(prompt: "PIN (Enter если нет): ")
            let items = try core.enumerateAccounts(devicePath: devicePath, pin: pin)
            if items.isEmpty { print("(нет)"); return }
            for a in items { print("- \(a.id) user=\(a.userName) rev=\(a.revision)") }
        }
    }

    struct Devices: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Список подключенных устройств")
        func run() throws {
            let devs = try FidoPassCore.shared.listDevices()
            if devs.isEmpty { print("(нет устройств)"); return }
            for d in devs { print("- path=\(d.path) | \(d.manufacturer) \(d.product)") }
        }
    }
}

@discardableResult
func readPIN(prompt: String = "Введите PIN ключа: ") -> String? {
    #if os(macOS)
    if let cstr = getpass(prompt) { return String(cString: cstr) }
    #endif
    fputs(prompt, stdout)
    fflush(stdout)
    return readLine()
}

FidoPass.main()
