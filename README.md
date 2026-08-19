# MESH_LINK

MESH_LINK is a secure, decentralized mesh communication application built with Flutter. It enables nearby devices to communicate and relay messages through a multi-hop mesh network using Bluetooth Low Energy (BLE).

The system combines device identity management, end-to-end security, BLE communication, and mesh routing to allow messages to travel between devices even when the sender and receiver are not directly connected.

## Architecture Diagram

![MESH\_LINK Architecture](architecture.png)

## Workflow Diagram

```text
┌─────────────┐
│ User Device │
└──────┬──────┘
       │
       ▼
┌─────────────────────┐
│ Identity Management │
│ Identity Generation │
│ Key Storage         │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Security Layer    │
│ E2E Encryption      │
│ Digital Signature   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  BLE Communication  │
│ Discovery           │
│ Connection Mgmt     │
│ Packet Handling     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Mesh Network      │
│ Routing             │
│ Neighbor Management │
│ Queue               │
│ Deduplication       │
└──────────┬──────────┘
           │
           ▼
     Nearby Mesh Nodes
           │
           ▼
       Destination
```

## How It Works

MESH_LINK follows a multi-stage message delivery process:

```text
Create
  │
  ▼
Security Processing
  │
  ▼
Broadcast
  │
  ▼
Forward
  │
  ▼
Queue
  │
  ▼
Delivered
```

### 1. Create

The user creates a message on their device. The application prepares the message for transmission through the mesh network.

### 2. Security Processing

Before transmission, the message passes through the security layer.

The system uses:

* End-to-End Encryption (E2EE)
* Digital signatures
* Device-specific identity and cryptographic keys

This ensures that messages are protected while travelling through intermediate mesh nodes.

### 3. Broadcast

The secured packet is transmitted using Bluetooth Low Energy (BLE).

The device discovers nearby MESH_LINK nodes and broadcasts the packet to available peers.

### 4. Forward

A nearby node receives the packet and determines whether it needs to forward the message.

The routing engine selects the next appropriate node, allowing the message to travel across multiple hops.

```text
Device A
   │
   ▼
Device B
   │
   ▼
Device C
   │
   ▼
Device D
   │
   ▼
Destination
```

The sender and destination therefore do not need to have a direct BLE connection.

### 5. Queue

Packets that cannot be immediately transmitted are maintained in a queue.

The queue allows the system to handle multiple packets and temporary communication limitations.

### 6. Deduplication

Because mesh networks may receive the same packet through multiple paths, MESH_LINK uses packet deduplication to prevent the same message from being forwarded repeatedly.

This reduces unnecessary network traffic and prevents packet loops.

### 7. Delivered

When the packet reaches its destination, it is processed and delivered to the intended user.

The destination device can then securely access the message.

---

## Architecture

MESH_LINK is divided into several logical layers.

### Identity Management Layer

The Identity Management Layer establishes the identity of each participating device.

Components:

* **Identity Generation** — Creates a unique identity for a device.
* **Key Storage** — Stores the cryptographic keys associated with the device.

This layer provides the foundation for authentication and secure communication.

### Security Layer

The Security Layer protects messages before they enter the mesh network.

Components:

* **End-to-End Encryption (E2EE)** — Protects message contents from unauthorized access.
* **Digital Signature** — Provides message authenticity and integrity.

Intermediate mesh nodes can forward encrypted packets without needing access to their contents.

### BLE Communication Layer

The BLE Communication Layer handles communication between nearby devices.

Components:

* **Discovery** — Detects nearby MESH_LINK devices.
* **Connection Management** — Establishes and manages BLE connections.
* **Packet Handler** — Processes incoming and outgoing network packets.

This layer provides the communication interface between the application and nearby mesh nodes.

### Mesh Network Layer

The Mesh Network Layer is responsible for multi-hop message delivery.

Components:

* **Routing Engine** — Determines how packets should be forwarded.
* **Neighbor Management** — Maintains information about nearby mesh nodes.
* **Queue** — Stores packets waiting for transmission.
* **Deduplication** — Prevents duplicate packets from being repeatedly forwarded.

Together, these components allow MESH_LINK to operate as a decentralized mesh network.

### Nearby Mesh Nodes

Every participating device can act as a mesh node.

A device can operate as:

* **Source** — Creates and sends a message.
* **Relay** — Forwards messages received from other devices.
* **Destination** — Receives and processes the final message.

This allows the network to extend beyond the direct communication range of a single device.

---

## Prerequisites

Before running MESH_LINK, make sure you have:

* Flutter SDK
* Dart SDK
* Git
* Android Studio or Android SDK
* An Android device or emulator
* Bluetooth Low Energy (BLE) capable device for mesh communication

Check your Flutter installation:

```bash
flutter doctor
```

Check the installed Flutter version:

```bash
flutter --version
```

---

## Setup

### 1. Clone the Repository

```bash
git clone https://github.com/Silentsummon/mesh_link.git
cd mesh_link
```

### 2. Install Dependencies

Install the Flutter dependencies:

```bash
flutter pub get
```

### 3. Check Available Devices

List the devices available to Flutter:

```bash
flutter devices
```

Example:

```text
Android SDK built for x86 • emulator-5554 • android-x86
```

### 4. Run the Application

Run MESH_LINK on a specific device:

```bash
flutter run -d <device_id>
```

For example:

```bash
flutter run -d emulator-5554
```

For a connected physical Android device:

```bash
flutter run -d <device_id>
```

### 5. Development

While the application is running, Flutter hot reload can be used to apply code changes without restarting the application.

Press:

```text
r
```

in the Flutter terminal to perform a hot reload.

---

## Project Structure

```text
mesh_link/
│
├── android/          # Android platform implementation
├── ios/              # iOS platform implementation
├── linux/            # Linux platform implementation
├── macos/            # macOS platform implementation
├── web/               # Web platform implementation
├── windows/           # Windows platform implementation
│
├── lib/               # Main Flutter application code
│
├── pubspec.yaml       # Flutter dependencies and project configuration
├── pubspec.lock       # Locked dependency versions
├── analysis_options.yaml
└── README.md          # Project documentation
```

The main application logic is contained inside the `lib/` directory.

---

## Security

Security is an integral part of the MESH_LINK architecture.

The security layer is responsible for:

* Device identity
* Cryptographic key management
* End-to-end message encryption
* Message authentication
* Digital signatures
* Protection against unauthorized message modification

Messages are secured before being transmitted through the mesh, allowing intermediate nodes to function as relays without requiring access to the message contents.

---

## Mesh Networking

MESH_LINK uses a multi-hop communication model.

Instead of requiring every device to communicate directly with the destination, intermediate devices can relay packets through the network.

Example:

```text
┌─────────┐
│ Device A│
└────┬────┘
     │
     ▼
┌─────────┐
│ Device B│
└────┬────┘
     │
     ▼
┌─────────┐
│ Device C│
└────┬────┘
     │
     ▼
┌─────────┐
│ Device D│
└─────────┘
```

This allows communication beyond the direct BLE range between two devices.

The mesh layer manages:

* Neighbor discovery
* Routing
* Packet forwarding
* Packet queuing
* Duplicate packet detection

---

## BLE Communication

Bluetooth Low Energy provides the underlying communication mechanism between nearby mesh nodes.

The BLE communication layer is responsible for:

1. Discovering nearby devices.
2. Establishing connections.
3. Sending and receiving packets.
4. Handling packet processing.
5. Communicating with the mesh routing layer.

BLE allows MESH_LINK nodes to communicate without requiring traditional internet connectivity.

---

## Data Flow

The complete MESH_LINK data flow is:

```text
┌───────────────┐
│     Create    │
└───────┬───────┘
        │
        ▼
┌───────────────────┐
│ Security Process  │
│ E2EE + Signature  │
└───────┬───────────┘
        │
        ▼
┌───────────────┐
│   Broadcast   │
│     BLE       │
└───────┬───────┘
        │
        ▼
┌───────────────┐
│    Forward    │
│ Mesh Routing  │
└───────┬───────┘
        │
        ▼
┌───────────────┐
│     Queue     │
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Delivered   │
└───────────────┘
```

---

