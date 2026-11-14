using System.Text.RegularExpressions;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>One actionable signing/install error shown in the launcher UI.</summary>
/// <param name="Code">Stable code (shared with docs and the device wrapper contract).</param>
/// <param name="Title">Short headline.</param>
/// <param name="Detail">What the tool said (tool text is data, never a command to run).</param>
/// <param name="Fix">What the user should do next.</param>
public sealed record SigningError(string Code, string Title, string Detail, string Fix);

/// <summary>
/// Maps Impactor / plumesign / SideStore-style error text to actionable launcher
/// messages. This is a study of the behaviour documented by S2Arm (Apache-2.0,
/// pack/jobs/impactor.py) and of Apple's well-known device-program errors; the
/// wording here is our own and the table is intentionally explicit so an
/// unmapped failure stays visible instead of being silently swallowed.
/// </summary>
public static class AppleErrorCatalog
{
    private sealed record Rule(Regex Pattern, string Code);

    private static readonly Rule[] Rules =
    {
        // Login/account state (Impactor side, before device work starts).
        new(new Regex("-80046", RegexOptions.Compiled), "login_identity_rejected"),
        new(new Regex("anisette error[\\s\\S]{0,600}?(?:dns error|os error 1100[1-4]|client error \\(connect\\)|error sending request|connection (?:refused|reset)|timed out)", RegexOptions.Compiled | RegexOptions.IgnoreCase), "signing_server_unreachable"),
        new(new Regex("developer api error 1100\\b|\\b1100\\b[^\\n]{0,40}session|session has expired|please log ?in again|not logged in", RegexOptions.Compiled | RegexOptions.IgnoreCase), "apple_session_expired"),
        new(new Regex("no account selected", RegexOptions.Compiled | RegexOptions.IgnoreCase), "account_not_selected"),
        new(new Regex("-2097\\d|-20101|incorrect|entered incorrectly", RegexOptions.Compiled), "apple_id_wrong"),
        new(new Regex("-21669|verification code|two.?factor|2fa", RegexOptions.Compiled | RegexOptions.IgnoreCase), "two_factor_wrong"),
        // Package/App ID limits. 9120 (10 App IDs / 7 days) is checked before the
        // 3-installed-apps limit so "app id" text does not fall into the wrong bucket.
        new(new Regex("app id limit|\\b10 app ids\\b|maximum number of app ids|(?:error|code)\\D{0,20}\\b9120\\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "free_appid_limit"),
        new(new Regex("maximum number of (installed )?apps\\b|\\b3 apps\\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "free_app_limit"),
        new(new Regex("(?:error|code)\\D{0,20}\\b9401\\b|app id with identifier[^\\n]{0,120}is not available", RegexOptions.Compiled | RegexOptions.IgnoreCase), "app_id_taken"),
        new(new Regex("mismatchedapplicationidentifierentitlement", RegexOptions.Compiled | RegexOptions.IgnoreCase), "entitlement_mismatch"),
        new(new Regex("already exists on this team", RegexOptions.Compiled | RegexOptions.IgnoreCase), "device_already_registered"),
        new(new Regex("unknown error (?:occured|occurred) while reading the file|zip64|name for this app is invalid", RegexOptions.Compiled | RegexOptions.IgnoreCase), "ipa_needs_repack"),
        new(new Regex("no device|device .{0,40}(?:not found|not connected|disconnected)", RegexOptions.Compiled | RegexOptions.IgnoreCase), "device_not_found"),
        new(new Regex("failed to (?:install|verify)|installation (?:failed|incomplete)", RegexOptions.Compiled | RegexOptions.IgnoreCase), "device_install_failed"),
    };

    private static readonly Dictionary<string, SigningError> Catalog = new(StringComparer.OrdinalIgnoreCase)
    {
        ["login_identity_rejected"] = new(
            "login_identity_rejected", "Apple ID sign-in was rejected.",
            "Impactor reported -80046.",
            "Open Impactor, sign in again with your own Apple ID (free accounts work), then retry the install."),
        ["signing_server_unreachable"] = new(
            "signing_server_unreachable", "Could not reach the signing service.",
            "The anisette/signing server used by Impactor is unreachable (DNS or connection error).",
            "Check this PC's network/proxy/VPN and try again in a minute; if it keeps failing, use a phone hotspot or another network."),
        ["apple_session_expired"] = new(
            "apple_session_expired", "Your Apple ID session expired.",
            "Apple's developer API answered 1100 (session expired).",
            "Open Impactor, sign in again, wait for the team list to appear, then retry. Free Apple ID sessions expire often."),
        ["account_not_selected"] = new(
            "account_not_selected", "Impactor has an Apple ID saved but none selected.",
            "plumesign reported 'No account selected'.",
            "Open Impactor -> Settings -> Account, select your account (if there are several, pick one), then retry."),
        ["apple_id_wrong"] = new(
            "apple_id_wrong", "The Apple ID or password was not accepted.",
            "Apple rejected the credentials (-2097x / -20101).",
            "Sign in again in Impactor. If the password changed, remove the account and add it again."),
        ["two_factor_wrong"] = new(
            "two_factor_wrong", "Two-factor authentication did not complete.",
            "Apple asked for a verification code (-21669 / 2FA).",
            "Open Impactor, sign in again and approve the code prompt; then retry the install."),
        ["free_appid_limit"] = new(
            "free_appid_limit", "Free Apple ID App ID limit reached (9120).",
            "Apple allows a free account to register 10 new App IDs per 7 days; deleting an app does not refund the slot.",
            "Wait for the 7-day window to roll over, or use a paid Apple Developer account. Switching the bundle identifier does not help until the limit resets."),
        ["free_app_limit"] = new(
            "free_app_limit", "Too many sideloaded apps on this device.",
            "A free Apple ID can keep at most 3 self-signed apps installed at a time.",
            "Delete one other sideloaded app from the phone, then retry the install."),
        ["app_id_taken"] = new(
            "app_id_taken", "This App ID is already registered to another team (9401).",
            "Apple refused to register the bundle identifier for this Apple ID.",
            "Change the shell bundle identifier in Settings (a unique value such as com.yourname.3ds2apple.shell), then retry."),
        ["entitlement_mismatch"] = new(
            "entitlement_mismatch", "The app's entitlements do not match the provisioning profile.",
            "mismatchedapplicationidentifierentitlement",
            "This usually means a stale signing profile: remove the app from the phone, sign in to Impactor again, then reinstall."),
        ["device_already_registered"] = new(
            "device_already_registered", "The phone is already registered in this team.",
            "plumesign tried to register the device again and Apple answered 'already exists on this team'.",
            "The launcher retries with sign-only + device install automatically. If this repeats, remove and re-add the Apple ID in Impactor."),
        ["ipa_needs_repack"] = new(
            "ipa_needs_repack", "The IPA could not be read.",
            "plumesign reported a broken/zip64 or invalid app name.",
            "Re-download the base shell IPA and reinstall the launcher package; the bundled Shell/3ds2apple-shell.ipa is corrupt."),
        ["device_not_found"] = new(
            "device_not_found", "No iPhone/iPad was found.",
            "No usable device was reported by the Apple device service.",
            "Connect the phone by USB, unlock it, tap Trust, and make sure Apple Devices/iTunes is installed."),
        ["device_install_failed"] = new(
            "device_install_failed", "Installing the signed app failed.",
            "See the signing log for the exact Impactor output.",
            "Unlock the phone, keep it connected and retry. If the free certificate expired, sign in again in Impactor."),
        ["impactor_missing"] = new(
            "impactor_missing", "The bundled signer is missing or was modified.",
            "Impactor/plumesign failed the pinned SHA-256 check.",
            "Reinstall the launcher package, or run launcher/windows/tools/fetch-impactor.ps1 on a PC that can reach GitHub."),
        ["generic_signing_failure"] = new(
            "generic_signing_failure", "Signing/install failed.",
            "The tool output did not match a known error.",
            "Read the log line above and search the exact text; then open Impactor (Apple ID/network/phone state are the usual causes)."),
    };

    /// <summary>All catalog entries, in stable code order, for the UI/docs.</summary>
    public static IReadOnlyDictionary<string, SigningError> All => Catalog;

    /// <summary>Match tool output against the ordered rule table.</summary>
    public static SigningError Explain(string? output)
    {
        if (string.IsNullOrWhiteSpace(output))
        {
            return Catalog["generic_signing_failure"];
        }
        foreach (var rule in Rules)
        {
            if (rule.Pattern.IsMatch(output))
            {
                return Catalog.TryGetValue(rule.Code, out var known)
                    ? known with { Detail = FirstMatchingLine(output, rule) }
                    : Catalog["generic_signing_failure"];
            }
        }
        return Catalog["generic_signing_failure"] with { Detail = LastMeaningfulLine(output) };
    }

    /// <summary>Look up a code without parsing text (e.g. a future wrapper error event).</summary>
    public static SigningError? Lookup(string? code) =>
        code is not null && Catalog.TryGetValue(code, out var error) ? error : null;

    private static string FirstMatchingLine(string output, Rule rule)
    {
        foreach (var line in output.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            if (rule.Pattern.IsMatch(line))
            {
                return Truncate(line.Trim());
            }
        }
        return Truncate(output.Trim());
    }

    private static string LastMeaningfulLine(string output)
    {
        var lines = output.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        for (var index = lines.Length - 1; index >= 0; index--)
        {
            var trimmed = lines[index].Trim();
            if (trimmed.Length > 0 && !trimmed.Contains("DEBUG", StringComparison.OrdinalIgnoreCase))
            {
                return Truncate(trimmed);
            }
        }
        return "no output";
    }

    private static string Truncate(string text) => text.Length > 300 ? text[..300] + "…" : text;
}
