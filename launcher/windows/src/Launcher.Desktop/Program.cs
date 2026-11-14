// 3ds2apple Windows launcher entry point.
//
// Two modes:
//   (no arguments)   graphical launcher (Avalonia).
//   --self-test      host-side self check without a window: verifies the pinned
//                    Impactor bundle, optional tool CLIs and the device-bridge
//                    contract parser, prints a report and exits non-zero on a
//                    real failure. This is what CI / WSL can run.
//   --ui-smoke       developer/Xvfb smoke run: load the XAML window, render, exit.
using System;
using Avalonia;
using ThreeDsTwoApple.Launcher.Core;

namespace ThreeDsTwoApple.Launcher.App;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (Array.Exists(args, a => a == "--self-test"))
        {
            return SelfTest.Run(Console.Out, Console.Error);
        }
        if (Array.Exists(args, a => a == "--version"))
        {
            Console.WriteLine(LauncherInfo.VersionLine);
            return 0;
        }
        if (Array.Exists(args, a => a == "--ui-smoke"))
        {
            // Surface Avalonia binding/theme warnings on the console during the smoke run.
            System.Diagnostics.Trace.Listeners.Add(new System.Diagnostics.ConsoleTraceListener());
        }
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        return 0;
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();
}