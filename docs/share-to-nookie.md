# Share to Nookie

The personal entitlements remain unchanged. Debug and Release now default
`NOOK_APP_GROUP_ID` to `group.e0b2da7e38d4c653.1`. This identifier was verified
in the signed entitlements and embedded profiles of the main app and all three
extensions in the user's `Nookie_0.1.2_1792236059.ipa`. No certificate, profile,
private key or signed application is copied into this repository.

If re-signing preserves this App Group, Share → **Nookie** can enqueue URLs for
the main app to import. Container access and end-to-end delivery still require
device validation; inspecting entitlements does not prove runtime access.

Without accessible group storage, Share → **Nookie** offers **复制链接并返回**.
Then open Nookie → Saved or Settings → **打开网页链接**, explicitly paste, and open.
The extension never claims this has already saved an article. The app never
reads the clipboard automatically.

For direct sharing, the signing provider must provision the **same App Group**
for the main app and NookShareSaveExtension (and NookShareExtension if using its
legacy Save Article action). Both bundles must specify that exact identifier in
`NOOK_APP_GROUP_ID` build setting (expanded into `NookieAppGroupIdentifier`
in each Info.plist) and their valid signed App Group
entitlement. An Info key alone does not grant access. If the signing provider
changes its groups, override the build setting with the new shared identifier;
do not invent one. Unsigned builds do not gain this entitlement automatically.

Once configured, the extension writes immutable URL envelopes to the shared
container. Foreground launch drains that queue into the existing article replica,
acknowledging only durable saves. Failed items remain for retry; corrupt envelopes
are retained but do not block valid ones. The app handles extraction and AI.
There is no forced launch through UIApplication/responder tricks for article shares.

References: [Apple shared data](https://developer.apple.com/documentation/technologyoverviews/shared-data),
[App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html).

Device checks: Safari URL and text-share URL; cancel; clipboard fallback with no
App Group; duplicate URL already in RSS; inaccessible original; Reader back/return;
if signing supports a group, cold launch queue import and interruption/retry.

This change does not enable App Groups, change signing, or run CI/IPA packaging.
