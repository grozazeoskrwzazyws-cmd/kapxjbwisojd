// Copyright © 2026 Kro. KroGram original materials.

import CommonCrypto
import LocalAuthentication
import Security
import SwiftUI

private struct PasscodeCredential: Codable, Sendable {
    let salt: Data
    let verifier: Data
    let iterations: UInt32
}

private enum PasscodeHasher {
    static func derive(_ passcode: String, salt: Data, iterations: UInt32) -> Data? {
        let outputLength = 32
        let passwordLength = passcode.utf8.count
        let saltLength = salt.count
        var output = Data(count: outputLength)
        let status = passcode.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        passwordLength,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                        saltLength,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                        outputLength
                    )
                }
            }
        }
        return status == kCCSuccess ? output : nil
    }

    static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

enum AppLockError: Error {
    case invalidPasscode
    case confirmationMismatch
    case incorrectPasscode
    case keychainFailure
}

@MainActor
final class AppLockManager: ObservableObject {
    private static let keychainKey = "app-lock.passcode.v1"
    private static let biometricsKey = "krogram.appLock.biometrics"
    private static let timeoutKey = "krogram.appLock.timeoutSeconds"
    private static let failedAttemptsKey = "krogram.appLock.failedAttempts"
    private static let lockoutDateKey = "krogram.appLock.lockoutDate"
    private static let iterations: UInt32 = 600_000

    @Published private(set) var isPasscodeEnabled = false
    @Published private(set) var isLocked = false
    @Published var usesBiometrics = false {
        didSet { UserDefaults.standard.set(usesBiometrics, forKey: Self.biometricsKey) }
    }
    @Published var autoLockSeconds = 300 {
        didSet { UserDefaults.standard.set(autoLockSeconds, forKey: Self.timeoutKey) }
    }
    @Published var errorKey: String?

    private var inactiveAt: Date?

    init() {
        do {
            let credential = try Self.loadCredential()
            isPasscodeEnabled = credential != nil
            isLocked = credential != nil
        } catch {
            isPasscodeEnabled = true
            isLocked = true
            errorKey = "appLock.error.storage"
        }
        usesBiometrics = UserDefaults.standard.bool(forKey: Self.biometricsKey)
        if let savedTimeout = UserDefaults.standard.object(forKey: Self.timeoutKey) as? NSNumber {
            autoLockSeconds = AutoLockInterval(rawValue: savedTimeout.intValue)?.rawValue
                ?? AutoLockInterval.fiveMinutes.rawValue
        } else {
            autoLockSeconds = AutoLockInterval.fiveMinutes.rawValue
        }
    }

    var canUseBiometrics: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func sceneDidChange(_ phase: ScenePhase) {
        switch phase {
        case .inactive, .background:
            if inactiveAt == nil { inactiveAt = Date() }
            if isPasscodeEnabled && autoLockSeconds == 0 { isLocked = true }
        case .active:
            defer { inactiveAt = nil }
            guard isPasscodeEnabled,
                  let inactiveAt,
                  Date().timeIntervalSince(inactiveAt) >= Double(autoLockSeconds) else { return }
            isLocked = true
        @unknown default:
            break
        }
    }

    func setPasscode(_ passcode: String, confirmation: String) async throws {
        guard Self.valid(passcode) else { throw AppLockError.invalidPasscode }
        guard passcode == confirmation else { throw AppLockError.confirmationMismatch }
        try await store(passcode)
    }

    func changePasscode(current: String, replacement: String, confirmation: String) async throws {
        guard await verify(current) else { throw AppLockError.incorrectPasscode }
        guard Self.valid(replacement) else { throw AppLockError.invalidPasscode }
        guard replacement == confirmation else { throw AppLockError.confirmationMismatch }
        try await store(replacement)
    }

    func disablePasscode(_ passcode: String) async throws {
        guard await verify(passcode) else { throw AppLockError.incorrectPasscode }
        Keychain.remove(Self.keychainKey)
        isPasscodeEnabled = false
        isLocked = false
        usesBiometrics = false
        clearFailedAttempts()
        errorKey = nil
    }

    func unlockWithPasscode(_ passcode: String) async -> Bool {
        let lockoutDate = UserDefaults.standard.double(forKey: Self.lockoutDateKey)
        guard Date().timeIntervalSince1970 >= lockoutDate else {
            errorKey = "appLock.error.lockout"
            return false
        }
        guard await verify(passcode) else {
            if errorKey == "appLock.error.storage" { return false }
            let failures = UserDefaults.standard.integer(forKey: Self.failedAttemptsKey) + 1
            UserDefaults.standard.set(failures, forKey: Self.failedAttemptsKey)
            if failures >= 5 {
                let exponent = min(failures - 5, 7)
                let delay = min(3_600, 30 * (1 << exponent))
                UserDefaults.standard.set(Date().addingTimeInterval(Double(delay)).timeIntervalSince1970,
                                          forKey: Self.lockoutDateKey)
                errorKey = "appLock.error.lockout"
            } else {
                errorKey = "appLock.error.incorrect"
            }
            return false
        }
        clearFailedAttempts()
        isLocked = false
        errorKey = nil
        return true
    }

    func unlockWithBiometrics() async -> Bool {
        guard usesBiometrics else { return false }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            errorKey = "appLock.error.biometricUnavailable"
            return false
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: L("appLock.biometricReason")
            )
            if success {
                clearFailedAttempts()
                isLocked = false
                errorKey = nil
            }
            return success
        } catch {
            errorKey = "appLock.error.biometricFailed"
            return false
        }
    }

    private func store(_ passcode: String) async throws {
        var salt = Data(count: 16)
        let randomStatus = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw AppLockError.keychainFailure }
        let iterations = Self.iterations
        let saltForDerivation = salt
        guard let verifier = await Task.detached(priority: .userInitiated, operation: {
            PasscodeHasher.derive(passcode, salt: saltForDerivation, iterations: iterations)
        }).value else { throw AppLockError.keychainFailure }
        let credential = PasscodeCredential(salt: salt, verifier: verifier, iterations: Self.iterations)
        do {
            try Keychain.set(try JSONEncoder().encode(credential), for: Self.keychainKey)
        } catch {
            throw AppLockError.keychainFailure
        }
        isPasscodeEnabled = true
        isLocked = false
        clearFailedAttempts()
        errorKey = nil
    }

    private func verify(_ passcode: String) async -> Bool {
        errorKey = nil
        guard let credential = try? Self.loadCredential() else {
            errorKey = "appLock.error.storage"
            return false
        }
                let expected = credential.verifier
                let salt = credential.salt
                let iterations = credential.iterations
                guard let actual = await Task.detached(priority: .userInitiated, operation: {
                        PasscodeHasher.derive(passcode, salt: salt, iterations: iterations)
                }).value else { return false }
                return PasscodeHasher.equals(actual, expected)
    }

            private func clearFailedAttempts() {
                UserDefaults.standard.removeObject(forKey: Self.failedAttemptsKey)
                UserDefaults.standard.removeObject(forKey: Self.lockoutDateKey)
            }

    private static func loadCredential() throws -> PasscodeCredential? {
        guard let data = try Keychain.get(keychainKey) else { return nil }
        return try JSONDecoder().decode(PasscodeCredential.self, from: data)
    }

    private static func valid(_ passcode: String) -> Bool {
        (4...8).contains(passcode.count)
            && passcode.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }
}

enum AutoLockInterval: Int, CaseIterable, Identifiable {
    case immediately = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300

    var id: Int { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .immediately: return "appLock.timeout.immediately"
        case .thirtySeconds: return "appLock.timeout.30"
        case .oneMinute: return "appLock.timeout.60"
        case .fiveMinutes: return "appLock.timeout.300"
        }
    }
}

struct AppLockView: View {
    @EnvironmentObject private var appLock: AppLockManager
    @State private var passcode = ""

    var body: some View {
        VStack(spacing: KroSpacing.lg) {
            Image(systemName: "lock.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)
            Text("appLock.title").font(.title2.weight(.semibold))
            Text("appLock.prompt")
                .font(.footnote)
                .foregroundStyle(.secondary)
            SecureField("appLock.passcode", text: $passcode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .multilineTextAlignment(.center)
                .onChange(of: passcode) { _, value in
                        passcode = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(8))
                }
            Button {
                Task {
                    if await appLock.unlockWithPasscode(passcode) { passcode = "" }
                }
            } label: {
                Text("appLock.unlock")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .disabled(passcode.count < 4)
            if appLock.usesBiometrics && appLock.canUseBiometrics {
                Button {
                    Task { _ = await appLock.unlockWithBiometrics() }
                } label: {
                    Label("appLock.unlockBiometric", systemImage: "faceid")
                }
                .buttonStyle(.bordered)
            }
            if let errorKey = appLock.errorKey {
                Text(LocalizedStringKey(errorKey))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(KroSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task {
            if appLock.usesBiometrics { _ = await appLock.unlockWithBiometrics() }
        }
    }
}

struct AppLockSettingsView: View {
    @EnvironmentObject private var appLock: AppLockManager
    @State private var currentPasscode = ""
    @State private var passcode = ""
    @State private var confirmation = ""
    @State private var statusKey: String?

    var body: some View {
        Form {
            Section {
                Text("appLock.disclosure")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if appLock.isPasscodeEnabled {
                    SecureField("appLock.currentPasscode", text: $currentPasscode)
                        .keyboardType(.numberPad)
                    SecureField("appLock.newPasscode", text: $passcode)
                        .keyboardType(.numberPad)
                    SecureField("appLock.confirmPasscode", text: $confirmation)
                        .keyboardType(.numberPad)
                    Button("appLock.changePasscode", action: changePasscode)
                        .disabled(currentPasscode.isEmpty || passcode.isEmpty || confirmation.isEmpty)
                    Button("appLock.disablePasscode", role: .destructive) {
                        Task { await disablePasscode() }
                    }
                    .disabled(currentPasscode.isEmpty)
                } else {
                    SecureField("appLock.newPasscode", text: $passcode)
                        .keyboardType(.numberPad)
                    SecureField("appLock.confirmPasscode", text: $confirmation)
                        .keyboardType(.numberPad)
                    Button("appLock.enablePasscode", action: enablePasscode)
                        .disabled(passcode.isEmpty || confirmation.isEmpty)
                }
                if let statusKey {
                    Text(LocalizedStringKey(statusKey))
                        .font(.footnote)
                        .foregroundStyle(statusKey.hasPrefix("appLock.error") ? .red : .secondary)
                }
            }

            if appLock.isPasscodeEnabled {
                Section("appLock.security") {
                    Toggle("appLock.biometrics", isOn: $appLock.usesBiometrics)
                        .disabled(!appLock.canUseBiometrics)
                    Picker("appLock.autoLock", selection: $appLock.autoLockSeconds) {
                        ForEach(AutoLockInterval.allCases) { interval in
                            Text(interval.titleKey).tag(interval.rawValue)
                        }
                    }
                }
            }
        }
        .navigationTitle("appLock.settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func enablePasscode() {
        Task {
            do {
                try await appLock.setPasscode(passcode, confirmation: confirmation)
                clearFields()
                statusKey = "appLock.enabled"
            } catch {
                statusKey = errorKey(for: error)
            }
        }
    }

    private func changePasscode() {
        Task {
            do {
                try await appLock.changePasscode(
                    current: currentPasscode,
                    replacement: passcode,
                    confirmation: confirmation
                )
                clearFields()
                statusKey = "appLock.changed"
            } catch {
                statusKey = errorKey(for: error)
            }
        }
    }

    private func disablePasscode() async {
        do {
            try await appLock.disablePasscode(currentPasscode)
            clearFields()
            statusKey = "appLock.disabled"
        } catch {
            statusKey = errorKey(for: error)
        }
    }

    private func clearFields() {
        currentPasscode = ""
        passcode = ""
        confirmation = ""
    }

    private func errorKey(for error: Error) -> String {
        switch error as? AppLockError {
        case .invalidPasscode: return "appLock.error.invalid"
        case .confirmationMismatch: return "appLock.error.mismatch"
        case .incorrectPasscode: return "appLock.error.incorrect"
        case .keychainFailure, nil: return "appLock.error.storage"
        }
    }
}

struct AppPrivacyShield: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}