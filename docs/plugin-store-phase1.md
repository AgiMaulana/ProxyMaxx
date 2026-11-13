# ProxyMaxx — Plugin Store (Phase 1) Product Specification

## 1. Overview

Phase 1 introduces a minimal Plugin Store in ProxyMaxx with two responsibilities:

1. **Sideload installation:** Install plugins from local `.pxplugin` packages.
2. **Permission management:** Let users understand, grant, inspect, and revoke plugin permissions.

The Plugin Store is a local plugin management interface, not an online marketplace.

ProxyMaxx is the authority for plugin identity, permission decisions, permission persistence, and permission enforcement.

## 2. Goals

- Install plugins from local package files.
- Validate plugin metadata and compatibility.
- Register installed plugins.
- Read permissions declared by each plugin.
- Present native permission consent UI.
- Persist permission decisions securely.
- Allow users to inspect and revoke permissions.
- Enforce permissions at protected API boundaries.

## 3. Non-goals

Explicitly excluded from Phase 1:

- Online plugin marketplace or discovery.
- Publisher accounts and developer registration.
- Automatic plugin updates.
- Cloud synchronization.
- Ratings, reviews, or analytics.
- Plugin configuration management.
- General-purpose scripting or automation.
- Arbitrary filesystem and network access.
- New plugin runtime or sandbox architecture.
- General-purpose plugin event system.
- Plugin diagnostics or audit dashboard.

Existing plugin execution capabilities may be reused where available, but expanding them is not part of this phase.

## 4. Plugin Package

### 4.1 Package format

Proposed extension: `.pxplugin`

The package contains:

- Plugin manifest.
- Plugin executable or entry point, according to the existing runtime contract.
- Required plugin resources.

The package format must be versioned.

### 4.2 Manifest

Every plugin must provide:

| Field | Description |
|---|---|
| `id` | Stable plugin identifier |
| `name` | Display name |
| `version` | Plugin version |
| `description` | Short description |
| `author` | Plugin author |
| `sdkVersion` | Required SDK compatibility |
| `permissions` | Declared permission requirements |
| `entryPoint` | Plugin entry point |

Each permission declaration contains:

- `id`: Permission identifier.
- `required`: Whether the plugin considers it essential.
- `reason`: Why the plugin needs the permission.

A manifest declaration is not authorization.

## 5. Sideload Installation

### 5.1 Installation flow

1. User opens Plugin Store.
2. User selects **Install from File**.
3. User selects a `.pxplugin` package.
4. ProxyMaxx validates the package.
5. ProxyMaxx displays an installation preview.
6. User confirms installation.
7. ProxyMaxx registers the plugin.
8. The plugin appears in the installed plugins list.

Installing a plugin must not automatically grant its permissions.

### 5.2 Package validation

ProxyMaxx validates:

- Package readability and integrity.
- Manifest presence and structure.
- Required metadata.
- Plugin identifier.
- SDK compatibility.
- Permission identifiers against the host registry.
- Entry-point presence.
- Duplicate plugin identifiers.

Invalid or incompatible packages must be rejected with a useful error.

### 5.3 Installation preview

Display:

- Plugin name.
- Version.
- Author.
- Description.
- Required permissions.
- Optional permissions.

The user must be able to cancel before installation.

### 5.4 Uninstallation

Users can uninstall an installed plugin.

Uninstallation must:

- Remove the plugin registration.
- Remove installed plugin package files.
- Revoke all permissions belonging to the plugin.
- Remove its stored permission decisions.

Uninstallation must not remove unrelated ProxyMaxx data.

## 6. Permission Registry

ProxyMaxx maintains a central registry of supported permissions.

### Initial permissions

| Permission ID | Description |
|---|---|
| `local-map.read` | Read Local Override rules |
| `local-map.create` | Create Local Override rules |
| `local-map.update` | Update Local Override rules |
| `local-map.delete` | Delete Local Override rules |

Permissions must be granular. Read access must not imply write or delete access.

The registry is controlled by ProxyMaxx. Plugins cannot introduce or register their own permissions.

Additional permissions should only be introduced when ProxyMaxx exposes a corresponding capability.

`filesystem.read` is excluded from the initial registry unless a concrete SDK feature requires it.

## 7. Permission Consent

### 7.1 Ownership

ProxyMaxx owns and displays the native consent UI.

Plugins request permission through the SDK. They cannot grant permissions themselves or replace the host's authorization flow.

### 7.2 Consent information

The consent UI displays:

- Plugin name.
- Permission name.
- Permission description.
- Developer-provided reason.
- Whether the permission is required or optional.

### 7.3 Consent behavior

- Only declared permissions can be requested.
- Unsupported permissions are rejected.
- Already-granted permissions do not require repeated consent.
- New permissions require a new decision.
- Permission scope or meaning changes must not silently inherit an old grant.
- Denied permissions remain denied until the user changes the decision.
- Users must be able to decline individual permissions when multiple permissions are requested.

The `required` field communicates plugin requirements; it does not override the user's decision.

## 8. Permission Management UI

### 8.1 Installed plugins

The Plugin Store displays installed plugins with:

- Name.
- Version.
- Author.

Selecting a plugin opens its details.

### 8.2 Plugin details

The details view displays:

- Plugin metadata.
- Declared permissions.
- Current permission status.
- Permission descriptions.
- Required or optional designation.
- Grant or revoke actions where applicable.
- Uninstall action.

Users must be able to understand which capabilities each plugin currently has.

### 8.3 Permission statuses

ProxyMaxx maintains these states:

| Status | Meaning |
|---|---|
| `GRANTED` | User has granted permission |
| `DENIED` | User has denied permission |
| `NOT_REQUESTED` | No decision has been made |
| `UNAVAILABLE` | Permission is unsupported or unavailable |

The UI must distinguish a permission that has merely been declared from one that has actually been granted.

## 9. Permission Storage

ProxyMaxx owns permission persistence.

Requirements:

- Associate permission decisions with stable plugin IDs.
- Persist decisions across application restarts.
- Keep declarations separate from authorization decisions.
- Prevent plugins from accessing or modifying permission records.
- Protect permission state against unauthorized modification.
- Fail closed if permission state cannot be verified.

Use macOS Keychain where appropriate for cryptographic material or integrity keys. Do not assume every permission record must be stored directly in Keychain.

Permission storage must be independent of plugin-provided data.

## 10. Permission Enforcement

Permission checks must happen at the protected API boundary.

For the initial Local Override integration:

| Operation | Required permission |
|---|---|
| Read rules | `local-map.read` |
| Create rule | `local-map.create` |
| Update rule | `local-map.update` |
| Delete rule | `local-map.delete` |

Requirements:

- Validate the requesting plugin's identity.
- Verify that the permission is declared.
- Verify that the permission is granted.
- Reject unauthorized operations.
- Respect revocation on subsequent protected operations.
- Do not rely exclusively on SDK-side checks.
- Do not allow alternate internal routes to bypass authorization.

If permission state is unavailable or corrupted, protected operations must be denied.

## 11. Logical Components

Phase 1 requires these logical responsibilities:

| Component | Responsibility |
|---|---|
| Package Installer | Reads and validates local plugin packages |
| Plugin Registry | Tracks installed plugin metadata |
| Permission Registry | Defines supported permissions |
| Permission Manager | Handles permission requests and decisions |
| Consent UI | Presents native permission consent |
| Permission Store | Persists permission decisions |
| Permission Enforcement | Protects host API operations |

These are logical responsibilities, not mandatory separate processes or services.

Prefer integrating with existing ProxyMaxx architecture rather than introducing unnecessary infrastructure.

## 12. Acceptance Criteria

### Installation

- [ ] User can install a local `.pxplugin` package.
- [ ] ProxyMaxx validates package and manifest contents.
- [ ] Invalid or incompatible packages are rejected.
- [ ] Duplicate plugin IDs are rejected.
- [ ] Installation preview displays plugin metadata and permissions.
- [ ] Installation does not automatically grant permissions.
- [ ] User can uninstall an installed plugin.

### Permission management

- [ ] ProxyMaxx maintains a central permission registry.
- [ ] Only registered permissions can be requested.
- [ ] Only declared permissions can be requested by a plugin.
- [ ] ProxyMaxx displays native consent UI.
- [ ] Users can inspect permission decisions.
- [ ] Permission decisions persist across restarts.
- [ ] Users can revoke granted permissions.
- [ ] Revocation affects subsequent protected operations.

### Security

- [ ] Plugins cannot modify permission records.
- [ ] Permission enforcement happens at protected API boundaries.
- [ ] SDK-side checks cannot bypass host authorization.
- [ ] Unverified permission state fails closed.
- [ ] Uninstallation removes associated permission decisions.

## 13. Future Considerations

Evaluate separately after Phase 1:

- Remote plugin marketplace.
- Plugin updates.
- Publisher identity and package signing.
- Additional permission categories.
- Temporary or session-scoped grants.
- Plugin runtime isolation.
- Plugin configuration management.
- Permission change notifications.
- Audit history and diagnostics.

None of these are prerequisites for the initial release.
