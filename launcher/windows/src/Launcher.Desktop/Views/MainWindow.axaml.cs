using System.Collections.Specialized;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using ThreeDsTwoApple.Launcher.App.ViewModels;

namespace ThreeDsTwoApple.Launcher.App.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        AvaloniaXamlLoader.Load(this);
        Opened += OnOpened;
    }

    private MainViewModel? ViewModel => DataContext as MainViewModel;

    private void OnOpened(object? sender, EventArgs e)
    {
        if (ViewModel is { } viewModel)
        {
            viewModel.BrowseRomRequested += OnBrowseRomRequested;
            ((INotifyCollectionChanged)viewModel.LogLines).CollectionChanged += (_, _) => ScrollLogToEnd();
        }
        ScrollLogToEnd();
    }

    private void ScrollLogToEnd()
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (this.FindControl<ListBox>("LogList") is { } logList && logList.ItemCount > 0)
            {
                logList.ScrollIntoView(logList.ItemCount - 1);
            }
        });
    }

    private async void OnBrowseRomRequested() => await PickRomAsync();

    private async void BrowseRomClicked(object? sender, RoutedEventArgs e) => await PickRomAsync();

    private async Task PickRomAsync()
    {
        if (ViewModel is not { } viewModel)
        {
            return;
        }
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Pick a decrypted 3DS ROM",
            AllowMultiple = false,
            FileTypeFilter = new[]
            {
                new FilePickerFileType("3DS ROM") { Patterns = new[] { "*.3ds", "*.cci", "*.ncch", "*.cxi" } },
                FilePickerFileTypes.All,
            },
        });
        if (files.Count == 0)
        {
            return;
        }
        var path = files[0].TryGetLocalPath();
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }
        viewModel.ImportPath = path;
        await viewModel.ImportAsync(new[] { path });
    }

    private async void BrowsePackClicked(object? sender, RoutedEventArgs e) => await PickToolAsync("3ds2apple-pack.exe", path => ViewModel!.PackPathSetting = path);
    private async void BrowseDevPushClicked(object? sender, RoutedEventArgs e) => await PickToolAsync("devpush.exe", path => ViewModel!.DevPushPathSetting = path);
    private async void BrowseBuilderClicked(object? sender, RoutedEventArgs e) => await PickToolAsync("builder-windows.exe", path => ViewModel!.BuilderPathSetting = path);

    private async Task PickToolAsync(string title, Action<string> apply)
    {
        if (ViewModel is null)
        {
            return;
        }
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Pick " + title,
            AllowMultiple = false,
            FileTypeFilter = new[] { new FilePickerFileType("Executable") { Patterns = new[] { "*.exe" } }, FilePickerFileTypes.All },
        });
        if (files.Count > 0 && files[0].TryGetLocalPath() is { } path)
        {
            apply(path);
        }
    }

}
