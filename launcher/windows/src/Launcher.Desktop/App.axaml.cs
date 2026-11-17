using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media.Imaging;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using ThreeDsTwoApple.Launcher.App.ViewModels;
using ThreeDsTwoApple.Launcher.App.Views;
using ThreeDsTwoApple.Launcher.Core.Localization;

namespace ThreeDsTwoApple.Launcher.App;

public partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var viewModel = new MainViewModel();
            desktop.MainWindow = new MainWindow { DataContext = viewModel };
            // Startup readiness self-check runs automatically; the status bar light turns green/red.
            var initialize = viewModel.InitializeAsync();
            if (desktop.Args?.Contains("--ui-smoke") == true)
            {
                var view = Environment.GetEnvironmentVariable("THREEDS2APPLE_UI_SMOKE_VIEW");
                if (string.Equals(view, "settings", StringComparison.OrdinalIgnoreCase))
                {
                    viewModel.OpenSettings();
                }
                else if (string.Equals(view, "deploy", StringComparison.OrdinalIgnoreCase))
                {
                    viewModel.ShowDeploy();
                }
                else if (string.Equals(view, "deploy-running", StringComparison.OrdinalIgnoreCase))
                {
                    viewModel.ShowDeploy();
                    viewModel.ShowDeployRunningForSmoke();
                }
                else if (string.Equals(view, "deploy-cancelled", StringComparison.OrdinalIgnoreCase))
                {
                    viewModel.ShowDeploy();
                    viewModel.ShowDeployCancelledForSmoke();
                }
                // Headless smoke run (CI/Xvfb): build the whole visual tree, render a few
                // frames, report and exit. Never used by the shipped launcher.
                DispatcherTimer.RunOnce(
                    async () =>
                    {
                        try
                        {
                            await initialize;
                        }
                        catch (Exception)
                        {
                            // a failed probe must not block the smoke render
                        }
                        // Dev-only: switch the language through the same view-model setter a
                        // ComboBox pick uses AFTER the window is live, then render: the
                        // screenshot proves the language box keeps showing the selected
                        // language after a switch (task-20 L3).
                        var smokeLanguage = Environment.GetEnvironmentVariable("THREEDS2APPLE_UI_SMOKE_LANGUAGE");
                        if (!string.IsNullOrWhiteSpace(smokeLanguage))
                        {
                            var preference = LanguageCatalog.ParsePreference(smokeLanguage);
                            var choice = viewModel.LanguageOptions.FirstOrDefault(option => option.Preference == preference);
                            if (choice is not null)
                            {
                                viewModel.SelectedLanguage = choice;
                                await Task.Delay(300);
                            }
                        }
                        var shot = Environment.GetEnvironmentVariable("THREEDS2APPLE_UI_SMOKE_SHOT");
                        if (!string.IsNullOrWhiteSpace(shot) && desktop.MainWindow is { } window && window.Bounds.Width > 0)
                        {
                            try
                            {
                                var size = new PixelSize(
                                    Math.Max(1, (int)Math.Ceiling(window.Bounds.Width)),
                                    Math.Max(1, (int)Math.Ceiling(window.Bounds.Height)));
                                using var bitmap = new RenderTargetBitmap(size, new Vector(96, 96));
                                bitmap.Render(window);
#pragma warning disable CS0618 // dev-only smoke screenshot; the replacement encoder API is not needed here
                                bitmap.Save(shot);
#pragma warning restore CS0618
                                Console.Out.WriteLine("ui-smoke: screenshot " + shot);
                            }
                            catch (Exception exception)
                            {
                                Console.Out.WriteLine("ui-smoke: screenshot failed: " + exception.Message);
                            }
                        }
                        Console.Out.WriteLine("ui-smoke: window created, XAML loaded and bindings evaluated");
                        Console.Out.Flush();
                        desktop.Shutdown(0);
                    },
                    TimeSpan.FromMilliseconds(2000));
            }
        }
        base.OnFrameworkInitializationCompleted();
    }
}