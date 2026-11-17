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
    private bool _shutdownInProgress;
    private bool _closeAllowed;

    public MainWindow()
    {
        AvaloniaXamlLoader.Load(this);
        Opened += OnOpened;
    }

    private MainViewModel? ViewModel => DataContext as MainViewModel;

    /// <summary>
    /// Closing the launcher while a Deploy is running must not leave a background
    /// 3dsrecomp/clang/lld/devpush/plumesign process behind: cancel the pipeline, wait for
    /// it to unwind (ProcessRunner kills the running stage's process tree), force-kill any
    /// tree still tracked, and only then let the window close.
    /// </summary>
    protected override void OnClosing(WindowClosingEventArgs e)
    {
        base.OnClosing(e);
        if (_closeAllowed || ViewModel is not { } viewModel || !viewModel.HasActiveWork)
        {
            return;
        }
        e.Cancel = true;
        if (_shutdownInProgress)
        {
            return;
        }
        _shutdownInProgress = true;
        _ = ShutdownThenCloseAsync(viewModel);
    }

    private async Task ShutdownThenCloseAsync(MainViewModel viewModel)
    {
        try
        {
            await viewModel.ShutdownAsync(TimeSpan.FromSeconds(12));
        }
        catch (Exception exception)
        {
            viewModel.Log("shutdown cleanup failed: " + exception.Message);
        }
        finally
        {
            _closeAllowed = true;
            Close();
        }
    }

    private void OnOpened(object? sender, EventArgs e)
    {
        if (ViewModel is { } viewModel)
        {
            viewModel.ExportLogRequested += OnExportLogRequested;
            ((INotifyCollectionChanged)viewModel.LogLines).CollectionChanged += (_, _) => ScrollLogToEnd();
        }
        ScrollLogToEnd();
    }

    private void ScrollLogToEnd()
    {
        Dispatcher.UIThread.Post(() =>
        {
            foreach (var name in new[] { "LogList", "DiagnosticsLogList" })
            {
                if (this.FindControl<ListBox>(name) is { } logList && logList.ItemCount > 0)
                {
                    logList.ScrollIntoView(logList.ItemCount - 1);
                }
            }
        });
    }

    private async void BrowseRomClicked(object? sender, RoutedEventArgs e)
    {
        try
        {
            await PickRomAsync();
        }
        catch (Exception exception)
        {
            ViewModel?.Log("file picker failed: " + exception.Message);
        }
    }

    private async Task PickRomAsync()
    {
        if (ViewModel is not { } viewModel)
        {
            return;
        }
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = viewModel.L.LibraryImportTitle,
            AllowMultiple = true,
            FileTypeFilter = new[]
            {
                new FilePickerFileType("3DS ROM") { Patterns = new[] { "*.3ds", "*.cci", "*.ncch", "*.cxi" } },
                FilePickerFileTypes.All,
            },
        });
        var paths = files.Select(file => file.TryGetLocalPath()).Where(path => !string.IsNullOrWhiteSpace(path)).Select(path => path!).ToList();
        if (paths.Count == 0)
        {
            return;
        }
        await viewModel.ImportAsync(paths);
    }

    private async void OnExportLogRequested()
    {
        try
        {
            if (ViewModel is not { } viewModel)
            {
                return;
            }
            var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = viewModel.L.SettingsLogsExport,
                SuggestedFileName = "3ds2apple-launcher-log.txt",
                DefaultExtension = "txt",
                FileTypeChoices = new[] { new FilePickerFileType("Text log") { Patterns = new[] { "*.txt", "*.log" } } },
            });
            if (file?.TryGetLocalPath() is { } path)
            {
                viewModel.ExportLogTo(path);
            }
        }
        catch (Exception exception)
        {
            ViewModel?.Log("export log failed: " + exception.Message);
        }
    }
}
