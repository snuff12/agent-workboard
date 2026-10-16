# Simple plugin connections

Users should select a service and connect it. Local executable paths, account labels, repository selectors, and developer client files belong in Advanced settings.

| Plugin | Normal connection |
| --- | --- |
| agent-memory | Connect detects amem in standard locations or the saved custom path and verifies help output. No memory search or capture during setup. |
| Orca | Connect detects the CLI, opens the installed app if needed, and lists registered local repositories. Check the repositories to connect; saved repositories, or else the repositories at board project folders, are preselected. |
| Google Workspace | Select Calendar and optional Gmail, then Sign in with Google. The separate release package contains the publisher's registered Desktop OAuth client. Tokens remain in Keychain; only successful authentication enables the plugin. |
| Slack | Paste a User OAuth token into a secure field. The workspace is detected automatically. No token file or workspace ID input; status sending stays separate. Browser OAuth is not implemented for Slack. |

## Google setup responsibilities

Google Cloud setup is done once by the publisher for this product. People downloading a publisher-configured plugin use the same registered Desktop client and authorize their own accounts. They do not create Cloud projects, enable APIs, download client JSON, or become developers.

| Who | Required steps |
| --- | --- |
| Publisher | Register the OAuth app/client, configure APIs and requested scopes, complete applicable production verification, and include Desktop client metadata in the separate plugin package. |
| Each user | Install the plugin, choose Calendar and optional Gmail, then select Sign in with Google and approve the selected access. |
| Publisher during testing | Add the intended accounts to the test-user list. This is a temporary development restriction, not the public onboarding flow. |
| Advanced/self-built users | Supply their own client only when choosing to build or operate a separate OAuth app. This is optional for normal downloads. |

Testing mode permits only registered test users and has token-lifetime restrictions. General distribution requires production configuration and applicable brand and scope verification, including the required public app information and privacy policy. Completing a test login does not establish public-release readiness. See [Google's verification and testing requirements](https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification).

## Design references

- [Raycast OAuthService](https://developers.raycast.com/utilities/oauth/oauthservice) separates provider setup from command use. Google requires a product-owned client rather than borrowing another extension's identity.
- [VS Code automatic discovery](https://code.visualstudio.com/docs/agents/reference/mcp-configuration) reuses known local tool locations/configurations, with explicit control over discovery sources. Workboard uses narrow CLI-path discovery; it does not scan other apps' tokens or private databases.
- [Raycast Calendar](https://manual.raycast.com/calendar) can use macOS EventKit accounts. That is a useful alternative for Calendar-only access, but it does not provide Gmail or the Google API's event/version contract; Workboard retains its separate Google OAuth provider.
- [Google native-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app) supports Desktop loopback callbacks and PKCE. Publisher app registration is a deployment prerequisite, not an end-user setup step.
- [Google scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification) applies to public distribution as required. Gmail remains optional; the core does not contain an account connection or proxy service.

## Host boundary

An installed manifest may declare `setup_methods`. Only an explicit connection flow invokes them through `plugin.setup`; core startup, ordinary metadata reads and disabled runtime calls remain inert. Setup may discover local tools or perform explicitly requested authentication, but cannot return any board mutations and does not enable itself or start the board service.

The host freezes the registry generation while a setup process runs. Disable/remove/configuration changes terminate it. Both later authentication steps and enablement accept the expected generation, preventing stale settings from enabling a replaced or reconfigured package. UI connection identities and per-flow generations reject delayed responses, including A → B → A changes. Cancelling a native connection terminates its CLI and provider process group.

Provider code and tool discovery remain in the separate packages. No Python, Google SDK, external accounts or integration executable discovery is added to core startup. Advanced configuration preserves existing and unknown settings.

Installing an updated package preserves existing settings and enabled state. CLI users pass `plugin install PACKAGE --replace`; the app handles replacement after explicit package selection. New installations stay disabled. The host stages and checks the package before replacing code and invalidates requests using the previous package generation.

## Publisher setup and verification

Register a Desktop Google OAuth client owned by this product. Enable Calendar API and Gmail API when offered, configure consent, and supply test users or complete applicable production verification. Keep the downloaded developer JSON outside Git; the default private build location is `.local/google-workspace/oauth-client.json`. Package with:

```sh
scripts/package-plugins.sh --google-oauth-client /private/path/desktop-client.json
scripts/verify-plugin-packages.sh "$PWD/target/debug/workboard"
```

The build copies only `client_id` and optional Desktop `client_secret` into `oauth-client.json`. It rejects web clients and strips user tokens/unrelated fields. The core bundle still excludes provider code and client metadata. Without a registered publisher client, Google connection is unavailable; the app must not pretend that a login button alone constitutes working integration.

Automated checks cover explicit-only setup, no implicit enablement/service startup, forbidden board mutations, generation conflicts, cancellation, local detection/selection, OAuth package sanitization, selected scopes, and Slack workspace detection. Real Google consent and account operations require their own execution evidence.

The October 16 verification passed Rust 71/Python 157 and the actual-source Swift runner, including cancellation and connection-discovery models. A release installation retained nine existing tasks and all saved plugin settings. Native Connect screens detected and connected amem and the matching Orca repository. The owner authorized Google's policy consent and Desktop client setup, but browser window control became unavailable before submission. Registration and real account login are not yet complete. No test client ID is installed as a working Google connection.
