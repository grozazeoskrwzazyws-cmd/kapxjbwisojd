# Push notifications

## Client flow

1. Request alert, sound, and badge permission from iOS.
2. Register with APNs and receive the app's device token.
3. After TDLib authorization is ready, call `registerDevice` with a `deviceTokenApplePush` token and the sandbox flag. TDLib returns a `pushReceiverId`; KroGram keeps it in memory.
4. Pass the complete received APNs payload as a JSON string to TDLib's `processPushNotification`.

KroGram also creates local notifications for incoming messages while it is running, observes per-chat mute/sound/preview settings, and updates the app badge. The APNs token and provider credentials are not written to logs or source control.

## Relay server design

The app does not include a relay server. A production relay needs:

- A trusted way to receive Telegram push payloads for registered receivers. `registerDevice` alone does not create this service.
- A TLS-authenticated mapping from the returned `pushReceiverId` and installation to its APNs device token.
- An APNs provider key held only by the server, with the correct Apple team, key, bundle ID, and environment.
- Payload forwarding to APNs so the app can pass the original payload to `processPushNotification`.
- Token rotation and logout cleanup, rate limits, and log redaction. Message text and APNs tokens should not be retained in application logs.

The relay must not call `processPushNotification` itself; that TDLib request belongs to the client that owns the Telegram session. Enable the Push Notifications capability and configure matching development/production provisioning before testing on a signed physical device.

TDLib references: [`registerDevice`](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1register_device.html), [`deviceTokenApplePush`](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1device_token_apple_push.html), and [`processPushNotification`](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1process_push_notification.html).
