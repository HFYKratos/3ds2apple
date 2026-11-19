using System.IO.Compression;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Device;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Distribution;
using ThreeDsTwoApple.Launcher.Core.Hardware;
using ThreeDsTwoApple.Launcher.Core.Localization;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Portable;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core;

/// <summary>
/// Host-side self test used by <c>3ds2apple-launcher.exe --self-test</c> and by
/// CI/WSL. It never needs a phone, a Mac or an Apple ID, never launches the UI
/// and only writes inside a temporary workspace. A FAIL line means the launcher
/// package is broken; a WARN line means an optional tool is missing on this PC.
/// </summary>
public static class SelfTest
{
    public static int Run(TextWriter output, TextWriter error)
    {
        var failures = 0;
        var warnings = 0;
        void Line(string status, string name, string detail = "")
        {
            var suffix = string.IsNullOrWhiteSpace(detail) ? string.Empty : " — " + detail;
            output.WriteLine($"[{status}] {name}{suffix}");
            if (status == "FAIL")
            {
                failures++;
            }
            else if (status == "WARN")
            {
                warnings++;
            }
        }

        var temporaryRoot = Path.Combine(Path.GetTempPath(), "3ds2apple-launcher-selftest-" + Guid.NewGuid().ToString("N")[..10]);
        try
        {
            output.WriteLine($"3ds2apple launcher self-test · {LauncherInfo.VersionLine}");
            var distribution = DistributionLayout.Prepare();
            output.WriteLine($"distribution root: {distribution.Root}");
            output.WriteLine($"distribution mode: {distribution.Describe()}");
            if (distribution.Warning is not null)
            {
                Line("WARN", "distribution payload", distribution.Warning);
            }
            output.WriteLine($"temporary workspace: {temporaryRoot}");
            var layout = PortableLayout.Resolve();
            output.WriteLine($"portable data root: {layout.DataRoot} ({layout.Kind}: {layout.Reason})");
            output.WriteLine();

            // 1. Version + shared identity constants.
            Line(!string.IsNullOrWhiteSpace(LauncherInfo.Version) && LauncherInfo.Version != "0.0.0" ? "PASS" : "FAIL",
                "launcher version", LauncherInfo.VersionLine);

            // 1b. Localization: OS detection, en/zh-Hans key parity, placeholders and live switching.
            var languageCases = new (string? Culture, string Expected)[]
            {
                (null, LanguageCatalog.EnglishTag),
                ("en-US", LanguageCatalog.EnglishTag),
                ("en-GB", LanguageCatalog.EnglishTag),
                ("zh-CN", LanguageCatalog.ChineseSimplifiedTag),
                ("zh-Hans", LanguageCatalog.ChineseSimplifiedTag),
                ("zh_CN", LanguageCatalog.ChineseSimplifiedTag),
                ("zh-TW", LanguageCatalog.EnglishTag),
                ("zh-Hant", LanguageCatalog.EnglishTag),
                ("de-DE", LanguageCatalog.EnglishTag),
            };
            var badDetection = languageCases.Where(item => LanguageCatalog.Detect(item.Culture) != item.Expected).Select(item => item.Culture ?? "<null>").ToList();
            Line(badDetection.Count == 0 ? "PASS" : "FAIL", "OS language detection",
                badDetection.Count == 0 ? "Simplified Chinese -> zh-Hans; everything else -> English" : "unexpected: " + string.Join(", ", badDetection));

            var englishKeys = LanguageCatalog.English.Keys.OrderBy(key => key, StringComparer.Ordinal).ToList();
            var chineseKeys = LanguageCatalog.ChineseSimplified.Keys.OrderBy(key => key, StringComparer.Ordinal).ToList();
            var parityOk = englishKeys.SequenceEqual(chineseKeys, StringComparer.Ordinal);
            var blankKeys = LanguageCatalog.Keys.Where(key =>
                string.IsNullOrWhiteSpace(LanguageCatalog.Text(LanguageCatalog.EnglishTag, key))
                || string.IsNullOrWhiteSpace(LanguageCatalog.Text(LanguageCatalog.ChineseSimplifiedTag, key))).ToList();
            var placeholderMismatch = LanguageCatalog.Keys.Where(key =>
                !LanguageCatalog.Placeholders(LanguageCatalog.English[key]).OrderBy(token => token, StringComparer.Ordinal)
                    .SequenceEqual(LanguageCatalog.Placeholders(LanguageCatalog.ChineseSimplified[key]).OrderBy(token => token, StringComparer.Ordinal))).ToList();
            Line(parityOk && blankKeys.Count == 0 && placeholderMismatch.Count == 0 ? "PASS" : "FAIL", "localization catalog (en + zh-Hans)",
                $"{LanguageCatalog.Keys.Count} keys" + (parityOk ? string.Empty : "; key mismatch")
                + (blankKeys.Count == 0 ? string.Empty : "; blank: " + string.Join(", ", blankKeys))
                + (placeholderMismatch.Count == 0 ? string.Empty : "; placeholders differ: " + string.Join(", ", placeholderMismatch)));

            var originalTag = Loc.CurrentTag;
            try
            {
                Loc.ApplyPreference(UiLanguagePreference.SimplifiedChinese);
                var chinese = Loc.T("nav.library") == "游戏库" && Loc.T("nav.import") == "导入";
                Loc.ApplyPreference(UiLanguagePreference.English);
                var english = Loc.T("nav.library") == "Library" && Loc.T("settings.title") == "Settings";
                Loc.ApplyPreference(UiLanguagePreference.System, "zh-CN");
                var systemChinese = Loc.CurrentTag == LanguageCatalog.ChineseSimplifiedTag;
                Loc.ApplyPreference(UiLanguagePreference.System, "en-US");
                var systemEnglish = Loc.CurrentTag == LanguageCatalog.EnglishTag;
                Line(chinese && english && systemChinese && systemEnglish ? "PASS" : "FAIL", "language override + system detection", "System/English/简体中文");
            }
            finally
            {
                Loc.ApplyPreference(UiLanguagePreference.System, originalTag == LanguageCatalog.ChineseSimplifiedTag ? "zh-CN" : "en-US");
            }

            // 1c. Hardware-aware compile line (3dsrecomp auto-parallelizes; no jobs setting).
            var hardware = HardwareProbe.Current;
            var hardwareOk = hardware.LogicalCores >= 1
                             && hardware.PhysicalCores >= 1
                             && hardware.PhysicalCores <= hardware.LogicalCores
                             && hardware.CompileJobs == hardware.LogicalCores
                             && hardware.TotalMemoryBytes > 0;
            Line(hardwareOk ? "PASS" : "FAIL", "hardware detection (compile parallelism)",
                hardwareOk ? hardware.Describe() : "implausible values: " + hardware.Describe());

            // 1d. Portable layout: data beside the executable, LocalAppData only as fallback.
            var portableLayout = PortableLayout.Resolve();
            var expectedPortable = Path.Combine(PortableLayout.ExeDirectory(), PortableLayout.DataDirectoryName, PortableLayout.WorkspaceDirectoryName);
            var portableOk = portableLayout.Kind == DataRootKind.Portable
                ? string.Equals(portableLayout.WorkspaceRoot, expectedPortable, StringComparison.OrdinalIgnoreCase)
                : portableLayout.Kind is DataRootKind.LocalAppData or DataRootKind.Explicit or DataRootKind.TempFallback;
            Line(portableOk ? "PASS" : "FAIL", "portable workspace root",
                $"{(portableLayout.Kind == DataRootKind.Portable ? "beside the executable" : "fallback")}: {portableLayout.WorkspaceRoot} ({portableLayout.Reason})");
            var probeLocalAppData = Path.Combine(temporaryRoot, "localappdata");
            var readOnlyProbe = PortableLayout.Resolve(
                exeDirectory: Path.Combine(temporaryRoot, "read-only-exe"),
                localAppDataRoot: probeLocalAppData,
                isWritable: path => path.StartsWith(probeLocalAppData, StringComparison.OrdinalIgnoreCase),
                dataRootOverride: null);
            Line(readOnlyProbe.Kind != DataRootKind.Portable && readOnlyProbe.WorkspaceRoot.EndsWith(PortableLayout.LegacyWorkspaceDirectoryName, StringComparison.OrdinalIgnoreCase)
                    ? "PASS" : "FAIL", "read-only launcher folder fallback",
                readOnlyProbe.Kind + ": " + readOnlyProbe.WorkspaceRoot);
            var legacyWorkspace = Path.Combine(temporaryRoot, "legacy-workspace");
            Directory.CreateDirectory(legacyWorkspace);
            File.WriteAllText(Path.Combine(legacyWorkspace, "state.json"),
                "{\"schemaVersion\":1,\"games\":[{\"titleID\":\"0004000000AAAA00\",\"displayName\":\"Migrated game\"}]}");
            var legacyPackage = Path.Combine(legacyWorkspace, "out", "packages", "0004000000AAAA00");
            Directory.CreateDirectory(legacyPackage);
            File.WriteAllText(Path.Combine(legacyPackage, "GameInfo.json"), "{\"schemaVersion\":1}");
            var portableWorkspaceRoot = Path.Combine(temporaryRoot, "portable-workspace");
            var migration = PortableLayout.MigrateLegacyWorkspace(portableWorkspaceRoot, legacyWorkspace);
            var migratedWorkspace = LauncherState.LauncherWorkspace.Open(portableWorkspaceRoot);
            var migratedGame = migratedWorkspace.Find("0004000000AAAA00");
            Line(migration.Migrated
                     && migratedGame is { DisplayName: "Migrated game" }
                     && File.Exists(Path.Combine(portableWorkspaceRoot, "state.json"))
                     && File.Exists(migration.MarkerPath)
                     && File.Exists(Path.Combine(legacyWorkspace, "state.json"))
                     ? "PASS" : "FAIL", "workspace migration (state.json + packages, legacy kept)",
                $"{migration.FilesCopied} file(s) copied; marker " + Path.GetFileName(migration.MarkerPath));

            // 1e. ROM metadata: localized SMDH names + publisher + package cover.png.
            var metadataNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["en"] = "Synthetic Game",
                ["zh-Hans"] = "合成测试游戏",
                ["ja"] = "テストゲーム",
            };
            var nameSelectionOk = GameNames.Resolve(metadataNames, "Synthetic Game", "zh-Hans") == "合成测试游戏"
                                  && GameNames.Resolve(metadataNames, "Synthetic Game", "en") == "Synthetic Game"
                                  && GameNames.Resolve(metadataNames, "Synthetic Game", "de") == "Synthetic Game"
                                  && GameNames.Resolve(null, "Fallback Name", "zh-Hans") == "Fallback Name"
                                  && GameNames.Resolve(new Dictionary<string, string> { ["ja"] = "テストゲーム" }, "Fallback Name", "en") == "Fallback Name";
            Line(nameSelectionOk ? "PASS" : "FAIL", "localized ROM display names (SMDH)",
                "zh-Hans -> 合成测试游戏; en/other -> English; missing -> default");
            var coverPackage = Path.Combine(temporaryRoot, "cover-package");
            Directory.CreateDirectory(coverPackage);
            File.WriteAllBytes(Path.Combine(coverPackage, "cover.png"), new byte[] { 0x89, 0x50, 0x4E, 0x47 });
            var coverPath = GameNames.ResolveCoverPath(coverPackage, "cover.png");
            Line(coverPath is not null && File.Exists(coverPath) ? "PASS" : "FAIL", "ROM icon cover.png (package-relative)",
                coverPath ?? "cover.png was not resolved");
            Line(GameNames.ResolvePublisher("  Nintendo  ") == "Nintendo" ? "PASS" : "FAIL", "SMDH publisher normalization", "publisher trimmed");

            // 2. Pinned Impactor digests must be exactly the official v2.7.3 assets.
            var pinsOk =
                ImpactorPins.Impactor.Sha256 == "ebf939f8c8e74b4cd693d2f9871db4b8304f12396181fdd17404a127427b9923"
                && ImpactorPins.PlumeSign.Sha256 == "94664749fbbceb9a16bf89583f473dafb9b35c8d058a9d8665dc963b3453c6fc"
                && ImpactorPins.Impactor.Bytes == 18_259_968
                && ImpactorPins.PlumeSign.Bytes == 10_759_168;
            Line(pinsOk ? "PASS" : "FAIL", "pinned Impactor v2.7.3 digests", pinsOk ? "match official release assets" : "launcher constants were modified");

            // 3. Optional: cross-check against a checked-in PINS.json when running from the repo.
            var pinsFile = FindRepoFile("launcher/windows/vendor/impactor/PINS.json");
            if (pinsFile is null)
            {
                Line("WARN", "PINS.json cross-check", "not found (normal outside a source checkout)");
            }
            else
            {
                var pinsMatch = PinsJsonMatches(pinsFile);
                Line(pinsMatch.Ok ? "PASS" : "FAIL", "PINS.json cross-check", pinsMatch.Detail);
            }

            // 4. Tool CLIs are optional on a dev machine, required in a distribution.
            var runner = new ProcessRunner();
            var locator = new ToolLocator(distribution.Root);
            var packPath = locator.FindPackCli();
            if (IsForeignWindowsBinary(packPath))
            {
                Line("PASS", "3ds2apple-pack", "bundled Windows binary present: " + packPath + " (execution skipped on this host; --self-test on Windows probes the version)");
            }
            else
            {
                var packProbe = ToolLocator.ProbeAsync("3ds2apple-pack", packPath, runner, new[] { "--version" }).GetAwaiter().GetResult();
                Line(packProbe.Ready ? "PASS" : "WARN", "3ds2apple-pack", packProbe.Describe());
            }

            var devPushPath = locator.FindDevPush();
            if (devPushPath is null)
            {
                Line("WARN", "devpush", "not found — device operations disabled until Bin/devpush.exe is bundled");
            }
            else if (IsForeignWindowsBinary(devPushPath))
            {
                Line("PASS", "devpush", "bundled Windows binary present: " + devPushPath + " (execution skipped on this host; the device contract is covered by unit tests)");
            }
            else
            {
                var devPush = new DevPushClient(runner, devPushPath);
                var probe = devPush.ProbeAsync().GetAwaiter().GetResult();
                Line(probe.Ready ? "PASS" : "FAIL", "devpush", probe.Describe());
            }

            // 4b. Windows local build (v2 default): report exactly what is missing; the
            //     Deploy page turns this into ONE actionable error and a Retry button.
            var localTools = LocalToolchainResolver.Resolve(locator);
            var localMissing = localTools.MissingTools();
            Line(localMissing.Count == 0 ? "PASS" : "WARN", "local build toolchain (3dsrecomp + LLVM/LLD)",
                localMissing.Count == 0
                    ? $"resolved: {localTools.RecompilerPath} + {localTools.LlvmBinDirectory}"
                    : "not complete: " + string.Join("; ", localMissing)
                      + " — Deploy shows one actionable error and Retry; install LLVM 23.1.6 + 3dsrecomp (tools/winbuild/README.md)");

            // 5. Workspace + persisted state round-trip.
            var workspace = LauncherState.LauncherWorkspace.Open(temporaryRoot);
            var entry = new Models.LibraryEntry
            {
                TitleID = "0004000000055E00",
                DisplayName = "Self-test game",
                RomPath = Path.Combine(temporaryRoot, "does-not-exist.cci"),
                State = "imported",
            };
            workspace.Upsert(entry);
            workspace.SaveState();
            var reloaded = LauncherState.LauncherWorkspace.Open(temporaryRoot);
            var found = reloaded.Find(entry.TitleID);
            Line(found is { DisplayName: "Self-test game" } ? "PASS" : "FAIL", "workspace state round-trip", reloaded.StatePath);

            // 6. GameInfo.json round-trip (schema shared with the iOS shell task).
            var gameInfoPath = Path.Combine(temporaryRoot, "GameInfo.json");
            var sha = new string('a', 64);
            var document = GameInfoWriter.Build("0004000000055E00", "Pokémon Y", "CTR-P-EK2A", 1, sha, 1024, sha, 2048, DateTimeOffset.UtcNow);
            GameInfoWriter.WriteAsync(gameInfoPath, document).GetAwaiter().GetResult();
            var readBack = GameInfoWriter.ReadAsync(gameInfoPath).GetAwaiter().GetResult();
            var gameInfoOk = readBack is { SchemaVersion: 1, TitleID: "0004000000055E00", Aot: true, PackAbiVersion: 1 }
                             && readBack.Pack is { } packInfo
                             && packInfo.File == "Frameworks/GamePack-0004000000055E00.dylib"
                             && packInfo.Size == 1024
                             && packInfo.Sha256 == sha
                             && readBack.PackBundled == true
                             && readBack.Rom.File == "GameRom.cci";
            Line(gameInfoOk ? "PASS" : "FAIL", "GameInfo.json round-trip (pack informational, bundle-relative)", gameInfoPath);
            var noPackDocument = GameInfoWriter.Build("0004000000055E00", "Pokémon Y", null, 1, null, null, sha, 2048, DateTimeOffset.UtcNow);
            var noPackJson = System.Text.Json.JsonSerializer.Serialize(noPackDocument, Util.Json.WriteOptions);
            Line(noPackDocument.Pack is null && !noPackJson.Contains("Frameworks/GamePack-", StringComparison.Ordinal) ? "PASS" : "FAIL",
                "GameInfo without pack metadata omits pack", "the bundle GameCatalog remains authoritative for the dylib");

            // 7. devpush/1 NDJSON contract parser (task-16 contract fixtures).
            var fixtureLines = new[]
            {
                "{\"schema\":\"devpush/1\",\"type\":\"begin\",\"command\":\"put\",\"udid\":\"00008030\"}",
                "{\"schema\":\"devpush/1\",\"type\":\"progress\",\"command\":\"put\",\"file\":\"GamePack.dylib\",\"bytesSent\":10,\"bytesTotal\":100,\"percent\":10}",
                "{\"schema\":\"devpush/1\",\"type\":\"warn\",\"command\":\"ls\",\"message\":\"path not found\"}",
                "{\"schema\":\"devpush/1\",\"type\":\"done\",\"command\":\"put\",\"remotePath\":\"Documents/Games/0004000000055E00/GamePack.dylib\",\"bytes\":100,\"sha256\":\"abc\"}",
                "{\"schema\":\"devpush/1\",\"type\":\"error\",\"command\":\"put\",\"error\":{\"code\":\"stall_timeout\",\"message\":\"stalled\"},\"exitCode\":6}",
            };
            var parsed = fixtureLines.Select(DevPushClient.ParseEventLine).ToList();
            var contractOk = parsed[0]?.Type == DevPushEventType.Begin
                             && parsed[1]?.Type == DevPushEventType.Progress
                             && parsed[2]?.Type == DevPushEventType.Warn
                             && parsed[3]?.Type == DevPushEventType.Done
                             && parsed[4]?.Type == DevPushEventType.Error
                             && DevPushClient.ParseEventLine("not json") is null;
            Line(contractOk ? "PASS" : "FAIL", "devpush/1 NDJSON contract parser", contractOk ? "begin/progress/warn/done/error" : "fixture lines did not parse");

            // 8. Push layout + build slug (stable strings other tasks depend on).
            var expectedRemote = "Documents/Games/" + GameInfoWriter.NormalizeTitleId("0004000000055e00");
            Line(expectedRemote == "Documents/Games/0004000000055E00" ? "PASS" : "FAIL", "push remote layout", expectedRemote);
            var slug = BuildSlug.From("Pokémon Y", "0004000000055E00");
            Line(slug == "pokemon-y-00055e00" ? "PASS" : "FAIL", "build slug", slug);

            // 8b. Deploy pipeline contract + composed-IPA gate. This is the regression
            //     guard for the reported bug: install must never ship a bare shell and
            //     push must use the actual installed bundle id.
            var stepOrderOk = DeployOrchestrator.StepCount == 5
                              && (int)DeployStepKind.Build == 0
                              && (int)DeployStepKind.Compose == 1
                              && (int)DeployStepKind.Install == 2
                              && (int)DeployStepKind.Push == 3
                              && (int)DeployStepKind.Verify == 4;
            Line(stepOrderOk ? "PASS" : "FAIL", "deploy pipeline step contract",
                "Build -> Compose -> Install -> Push -> Verify (installed bundle id is used for push)");
            var verifierRoot = Path.Combine(temporaryRoot, "verifier");
            Directory.CreateDirectory(verifierRoot);
            var fakePackPath = Path.Combine(verifierRoot, "GamePack-fake.dylib");
            File.WriteAllBytes(fakePackPath, new byte[] { 0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0 });
            var fakePack = new ComposedPack("0004000000055E00", "Self-test game", null, 1, fakePackPath);
            var goodIpa = Path.Combine(verifierRoot, "good.ipa");
            WriteSyntheticAppIpa(goodIpa, fakePack.TitleID, includePack: true, catalogGames: 1, schemaVersion: 2);
            var goodVerification = ComposedIpaVerifier.Verify(goodIpa, new[] { fakePack });
            var bareIpa = Path.Combine(verifierRoot, "bare.ipa");
            WriteSyntheticAppIpa(bareIpa, fakePack.TitleID, includePack: false, catalogGames: 0, schemaVersion: 2);
            var bareVerification = ComposedIpaVerifier.Verify(bareIpa, new[] { fakePack });
            var noPacksVerification = ComposedIpaVerifier.Verify(goodIpa, Array.Empty<ComposedPack>());
            Line(goodVerification.Ok && !bareVerification.Ok && !noPacksVerification.Ok ? "PASS" : "FAIL",
                "composed IPA gate (real packs + non-empty schema-2 catalogue)",
                goodVerification.Ok
                    ? "accepts a real pack + catalogue; rejects bare shell (" + bareVerification.ErrorCode + ") and zero packs (" + noPacksVerification.ErrorCode + ")"
                    : "a valid composed IPA was rejected: " + goodVerification.Describe());

            // 9. Optional pinned Impactor bundle (present in a distribution, absent in dev).
            var bundle = ImpactorBundle.Locate(distribution.Root).Verify();
            if (!Directory.Exists(bundle.Directory))
            {
                Line("WARN", "Impactor bundle", "ThirdParty/Impactor is not present (normal in a source checkout)");
            }
            else
            {
                Line(bundle.Ready ? "PASS" : "FAIL", "Impactor bundle", bundle.Summary);
            }

            // 10. Single-file distribution payload: embedded resources, extraction and the ROM-free shell template.
            if (!distribution.HasEmbeddedPayload)
            {
                Line("WARN", "embedded distribution payload", "not present in this developer build (normal for Debug/source builds)");
            }
            else
            {
                var relativePaths = distribution.Payload.Select(file => file.RelativePath).ToHashSet(StringComparer.Ordinal);
                var missingExpected = DistributionLayout.ExpectedRelativePaths.Where(path => !relativePaths.Contains(path)).ToList();
                Line(missingExpected.Count == 0 ? "PASS" : "FAIL", "embedded payload inventory",
                    missingExpected.Count == 0
                        ? $"{distribution.Payload.Count} files (shell IPA+manifest, Impactor/plumesign+licences, Bin tools, LICENSE/NOTICE/THIRD_PARTY)"
                        : "missing: " + string.Join(", ", missingExpected));

                var missingOnDisk = distribution.Payload
                    .Where(file => !File.Exists(Path.Combine(distribution.Root, file.RelativePath.Replace('/', Path.DirectorySeparatorChar))))
                    .Select(file => file.RelativePath)
                    .ToList();
                Line(missingOnDisk.Count == 0 ? "PASS" : "FAIL", "extracted distribution files",
                    missingOnDisk.Count == 0 ? "all payload files present under " + distribution.Root : "missing: " + string.Join(", ", missingOnDisk));
                var extractionOutsideExe = !string.Equals(
                    Path.TrimEndingDirectorySeparator(distribution.Root),
                    Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory),
                    StringComparison.OrdinalIgnoreCase);
                var extractionKnownRoot = distribution.Root.StartsWith(PortableLayout.ExeDirectory(), StringComparison.OrdinalIgnoreCase)
                                          || distribution.Root.StartsWith(PortableLayout.LocalAppDataRoot(), StringComparison.OrdinalIgnoreCase);
                Line(extractionOutsideExe && extractionKnownRoot ? "PASS" : "FAIL", "single-file extraction target",
                    (extractionOutsideExe && extractionKnownRoot
                        ? (distribution.Portable ? "portable beside the launcher: " : "LocalAppData fallback: ")
                        : "unexpected extraction folder: ") + distribution.Root + " (" + (distribution.Reason ?? "no reason") + ")");

                var shellDirectory = Path.Combine(distribution.Root, "Shell");
                var shell = ShellManifest.ReadAsync(shellDirectory).GetAwaiter().GetResult();
                if (shell is null)
                {
                    Line("FAIL", "base shell template", "Shell/manifest.json is missing from the distribution payload");
                }
                else
                {
                    var shellVerification = shell.Verify(shellDirectory);
                    var shellRules = ShellTemplateRules.ValidateManifest(shell);
                    Line(shellVerification.Ok && shellRules.Ok ? "PASS" : "FAIL", "base shell template (ROM-free)",
                        shellVerification.Ok && shellRules.Ok
                            ? $"v{shell.Version} {shell.BundleId} ({shell.FileName}), pinned SHA-256/size"
                            : (shellVerification.Error ?? string.Empty) + " " + (shellRules.Error ?? string.Empty));
                }

                var licenseTexts = new[] { "licenses/LICENSE", "licenses/NOTICE", "licenses/THIRD_PARTY.md" };
                var missingLicenseTexts = licenseTexts.Where(path => !relativePaths.Contains(path)).ToList();
                Line(missingLicenseTexts.Count == 0 ? "PASS" : "FAIL", "licence and notice texts",
                    missingLicenseTexts.Count == 0 ? "LICENSE, NOTICE and THIRD_PARTY.md are embedded" : "missing: " + string.Join(", ", missingLicenseTexts));

                var recompEmbedded = relativePaths.Contains("Bin/3dsrecomp.exe");
                Line(recompEmbedded ? "PASS" : "FAIL", "bundled 3dsrecomp payload",
                    recompEmbedded ? "Bin/3dsrecomp.exe is embedded (local build needs no Mac)" : "Bin/3dsrecomp.exe is missing from the embedded payload");
                var llvmEmbedded = relativePaths.Contains("Bin/llvm/bin/clang.exe");
                Line(llvmEmbedded ? "PASS" : "WARN", "bundled LLVM payload",
                    llvmEmbedded
                        ? "Bin/llvm/** is embedded (full local build works offline)"
                        : "Bin/llvm is not bundled in this build; Deploy shows one actionable local-toolchain error until the official LLVM 23.1.6 tools are staged (known packaging gap)");
            }

            output.WriteLine();
            output.WriteLine(failures == 0
                ? (warnings == 0 ? "SELF-TEST OK" : $"SELF-TEST OK with {warnings} warning(s)")
                : $"SELF-TEST FAILED ({failures} failure(s), {warnings} warning(s))");
            return failures == 0 ? 0 : 1;
        }
        catch (Exception exception)
        {
            error.WriteLine("self-test crashed: " + exception);
            return 1;
        }
        finally
        {
            try
            {
                if (Directory.Exists(temporaryRoot))
                {
                    Directory.Delete(temporaryRoot, recursive: true);
                }
            }
            catch (IOException)
            {
                // best effort cleanup
            }
        }
    }

    /// <summary>True when a bundled tool is a Windows .exe running under a non-Windows host (WSL/CI).</summary>
    private static bool IsForeignWindowsBinary(string? path) =>
        !string.IsNullOrWhiteSpace(path)
        && !OperatingSystem.IsWindows()
        && path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);

    /// <summary>Minimal composed-IPA fixture for the verifier self-check (packs + schema-2 catalogue).</summary>
    private static void WriteSyntheticAppIpa(string path, string titleId, bool includePack, int catalogGames, int schemaVersion)
    {
        using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
        var catalog = archive.CreateEntry("Payload/demo.app/GameCatalog.json");
        using (var writer = new StreamWriter(catalog.Open()))
        {
            var games = string.Join(",", Enumerable.Range(0, catalogGames).Select(_ =>
                "{\"titleID\":\"" + titleId + "\",\"packFile\":\"Frameworks/GamePack-" + titleId + ".dylib\"}"));
            writer.Write("{\"schemaVersion\":" + schemaVersion + ",\"games\":[" + games + "]}");
        }
        if (includePack)
        {
            var packEntry = archive.CreateEntry("Payload/demo.app/Frameworks/GamePack-" + titleId + ".dylib");
            using var stream = packEntry.Open();
            stream.Write(new byte[] { 0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0 });
        }
    }

    private static (bool Ok, string Detail) PinsJsonMatches(string path)
    {
        try
        {
            using var document = Json.TryParse(File.ReadAllText(path));
            if (document is null)
            {
                return (false, "PINS.json is not valid JSON");
            }
            var binaries = Json.Array(document.RootElement, "binaries");
            foreach (var binary in binaries)
            {
                var name = Json.String(binary, "fileName");
                var sha = Json.String(binary, "sha256");
                var bytes = Json.Long(binary, "bytes");
                var pin = ImpactorPins.All.FirstOrDefault(p => p.FileName == name);
                if (pin is null)
                {
                    return (false, $"PINS.json has unknown binary {name}");
                }
                if (!string.Equals(pin.Sha256, sha, StringComparison.OrdinalIgnoreCase) || pin.Bytes != bytes)
                {
                    return (false, $"PINS.json disagrees with launcher constants for {name}");
                }
            }
            return binaries.Count == ImpactorPins.All.Count ? (true, "checked-in pins match launcher constants") : (false, "PINS.json is incomplete");
        }
        catch (IOException exception)
        {
            return (false, exception.Message);
        }
    }

    private static string? FindRepoFile(string relativePath)
    {
        var candidates = new List<string> { Path.Combine(AppContext.BaseDirectory, relativePath), Path.GetFullPath(relativePath) };
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        for (var depth = 0; depth < 8 && directory is not null; depth++)
        {
            candidates.Add(Path.Combine(directory.FullName, relativePath));
            directory = directory.Parent;
        }
        return candidates.FirstOrDefault(File.Exists);
    }
}
