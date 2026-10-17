// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class PushNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var errorText: String?
    @Published private(set) var pushReceiverID: Int64?

    private let center = UNUserNotificationCenter.current()
    private var deviceToken: String?
    private var registeredDeviceToken: String?
    private var registeringDeviceToken: String?
    private var service: TelegramService?
    private var serviceStarted = false
    private var serviceReady = false
    private var pendingPayloads: [(payload: String, completion: ((UIBackgroundFetchResult) -> Void)?)] = []

    private override init() {
        super.init()
        center.delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                errorText = nil
            }
        } catch {
            errorText = L("err.generic")
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
        if authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral {
            UIApplication.shared.registerForRemoteNotifications()
            registerDeviceIfReady()
        }
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func setDeviceToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        registerDeviceIfReady()
    }

    func setRegistrationError(_ error: Error) {
        errorText = error.localizedDescription
    }

    func attach(_ service: TelegramService?) {
        let replacingSession = self.service != nil && service == nil
        self.service = service
        serviceStarted = false
        serviceReady = false
        pushReceiverID = nil
        registeredDeviceToken = nil
        registeringDeviceToken = nil
        if replacingSession { pendingPayloads.removeAll() }
    }

    func discardPendingPushes() {
        pendingPayloads.removeAll()
    }

    func markServiceStarted(_ service: TelegramService) {
        guard self.service === service else { return }
        serviceStarted = true
        let payloads = pendingPayloads
        pendingPayloads.removeAll()
        for item in payloads { process(item.payload, using: service, completion: item.completion) }
    }

    func markServiceReady(_ service: TelegramService) {
        guard self.service === service else { return }
        serviceReady = true
        registerDeviceIfReady()
    }

    func receiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        completion: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        var payload: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String else { continue }
            payload[key] = value
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let encoded = String(data: data, encoding: .utf8) else {
            errorText = L("err.generic")
            completion(.failed)
            return
        }
        guard serviceStarted, let service else {
            pendingPayloads.append((encoded, nil))
            completion(.noData)
            return
        }
        process(encoded, using: service, completion: completion)
    }

    func updateBadge(_ count: Int) {
        let count = max(0, count)
        Task {
            do {
                try await center.setBadgeCount(count)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func notifyIncomingMessage(
        chatID: Int64,
        messageID: Int64?,
        title: String,
        body: String,
        soundEnabled: Bool
    ) {
        guard authorizationStatus == .authorized
                || authorizationStatus == .provisional
                || authorizationStatus == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = soundEnabled ? .default : nil
        content.userInfo = ["chat_id": chatID]
        let identifier = "chat.\(chatID).message.\(messageID ?? Int64(Date().timeIntervalSince1970 * 1_000))"
        center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.errorText = error.localizedDescription }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        processRemoteIfNeeded(notification.request.content.userInfo)
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        processRemoteIfNeeded(response.notification.request.content.userInfo)
        completionHandler()
    }

    private func processRemoteIfNeeded(_ userInfo: [AnyHashable: Any]) {
        guard userInfo["aps"] != nil else { return }
        receiveRemoteNotification(userInfo) { [weak self] result in
            if result == .failed { self?.errorText = L("err.generic") }
        }
    }

    private func registerDeviceIfReady() {
        guard serviceReady, let service, let deviceToken,
              deviceToken != registeredDeviceToken,
              deviceToken != registeringDeviceToken else { return }
        registeringDeviceToken = deviceToken
        #if DEBUG
        let isSandbox = true
        #else
        let isSandbox = false
        #endif
        Task {
            do {
                let receiverID = try await service.registerDevice(token: deviceToken, isSandbox: isSandbox)
                guard self.service === service else { return }
                pushReceiverID = receiverID
                registeredDeviceToken = deviceToken
                errorText = nil
            } catch {
                if self.service === service { errorText = TGErrors.message(for: error) }
            }
            guard self.service === service else { return }
            if registeringDeviceToken == deviceToken { registeringDeviceToken = nil }
            if self.deviceToken != deviceToken { registerDeviceIfReady() }
        }
    }

    private func process(
        _ payload: String,
        using service: TelegramService,
        completion: ((UIBackgroundFetchResult) -> Void)? = nil
    ) {
        Task {
            do {
                try await service.processPushNotification(payload: payload)
                completion?(.newData)
                errorText = nil
            } catch {
                completion?(.failed)
                errorText = TGErrors.message(for: error)
            }
        }
    }
}

@MainActor
final class KroGramAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationManager.shared.setDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationManager.shared.setRegistrationError(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        PushNotificationManager.shared.receiveRemoteNotification(userInfo, completion: completionHandler)
    }
}
