## Setup & Running the Application

### Prerequisites

Make sure you have the following installed:

- Flutter SDK
- Dart SDK
- Android Studio or an Android device/emulator
- Git

Check your Flutter installation:

```bash
flutter doctor
```

### Clone the Repository

```bash
git clone https://github.com/Silentsummon/mesh_link.git
cd mesh_link
```

### Install Dependencies

Run:

```bash
flutter pub get
```

### Check Available Devices

To see all devices available to Flutter:

```bash
flutter devices
```

Example:

```text
2 connected devices:

Android SDK built for x86 (mobile) • emulator-5554 • android-x86
Chrome (web)                      • chrome        • web-javascript
```

### Run the Application

Run MESH_LINK on the desired device using its device ID:

```bash
flutter run -d <device_id>
```

For example:

```bash
flutter run -d emulator-5554
```

For a physical Android device:

```bash
flutter run -d <your_device_id>
```

### Development

While the application is running, Flutter's hot reload can be used to apply code changes without restarting the application.

Press:

```text
r
```

in the terminal running Flutter to perform a hot reload.

### Troubleshooting

If Flutter does not detect your device, run:

```bash
flutter doctor
```

and:

```bash
flutter devices
```

Resolve any reported configuration or device issues before running the application again.
