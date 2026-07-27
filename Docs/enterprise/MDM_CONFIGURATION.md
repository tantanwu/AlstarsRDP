# Enterprise Managed Configuration

RemoteDesktop reads managed settings at application launch. Administrators can
deliver the keys either in the `com.apple.configuration.managed` dictionary or
as forced preferences for the application bundle identifier. Forced direct
preferences take precedence over values in the managed dictionary.

The current development bundle identifier is `com.example.RemoteDesktop` and
must be replaced with the approved production identifier before deployment.

## Supported keys

| Key | Type | Accepted values | Effect |
|---|---|---|---|
| `AutomaticReconnectEnabled` | Boolean | `true`, `false` | Forces automatic reconnect on or off. |
| `MaximumReconnectAttempts` | Integer | `0...255` | Caps per-profile and default reconnect attempts. |
| `ForcedScaleMode` | String | `fit`, `actualSize`, `dynamicResolution` | Forces the display scaling mode. |
| `MaximumRedirectionPreset` | String | `secure`, `standard`, `complete` | Caps resource redirection and removes disallowed settings before connection. |
| `AllowCredentialSaving` | Boolean | `true`, `false` | Controls new Keychain saves. When false, saving controls are disabled and profile saves remove stored references. |
| `AllowPrivateDiagnosticExport` | Boolean | `true`, `false` | Controls whether support exports may contain unredacted host names and addresses. |

Unknown keys and values with the wrong type are ignored. Invalid enum strings
and integers outside `0...255` are ignored. Removing a policy takes effect after
the application is restarted.

## Redirection levels

`secure` permits text clipboard and remote audio playback. `standard` also
permits image clipboard. `complete` permits all resource switches, although a
capability remains unavailable when the current FreeRDP build does not provide
its channel implementation. Shared folders are removed when the maximum level
is `secure` or `standard`.

Policy enforcement occurs when settings are loaded, when a profile is saved,
and again when a session is prepared. This prevents imported profiles or stale
UI state from bypassing the effective policy. Existing user preferences remain
stored where possible so they can become effective again after a temporary
policy is removed.

## Example managed dictionary

```xml
<key>com.apple.configuration.managed</key>
<dict>
    <key>AutomaticReconnectEnabled</key>
    <false/>
    <key>MaximumReconnectAttempts</key>
    <integer>2</integer>
    <key>ForcedScaleMode</key>
    <string>fit</string>
    <key>MaximumRedirectionPreset</key>
    <string>secure</string>
    <key>AllowCredentialSaving</key>
    <false/>
    <key>AllowPrivateDiagnosticExport</key>
    <false/>
</dict>
```

Validate the final profile in a test MDM tenant before production rollout. Do
not place passwords, proxy authorization headers, Keychain references, or test
credentials in a configuration profile.
