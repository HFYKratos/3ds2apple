using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media.Imaging;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using ThreeDsTwoApple.Launcher.App.ViewModels;
using ThreeDsTwoApple.Launcher.App.Views;

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
            _ = viewModel.InitializeAsync();
            if (desktop.Args?.Contains("--ui-smoke") == true)
            {
                var view = Environment.GetEnvironmentVariable("THREEDS2APPLE_UI_SMOKE_VIEW");
                if (string.Equals(view, "settings", StringComparison.OrdinalIgnoreCase))
                {
                    viewModel.OpenSettings();
                }
                else if (string.Equals(view, "import", StringComparison.OrdinalIgnoreCase))
                {
                    viewModel.ShowImport();
                }
                // Headless smoke run (CI/Xvfb): build the whole visual tree, render a few
                // frames, report and exit. Never used by the shipped launcher.
                DispatcherTimer.RunOnce(
                    () =>
                    {
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