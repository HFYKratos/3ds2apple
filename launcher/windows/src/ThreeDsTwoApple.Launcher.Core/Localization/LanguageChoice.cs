using System.ComponentModel;

namespace ThreeDsTwoApple.Launcher.Core.Localization;

/// <summary>
/// One selectable UI language in Settings. The label is refreshed IN PLACE when the UI
/// language changes: rebuilding the ComboBox item list replaces the selected item object,
/// and Avalonia then shows an empty language box after a switch. Keeping the objects (and
/// therefore the selection) stable fixes that without changing the persisted format.
/// </summary>
public sealed class LanguageChoice : INotifyPropertyChanged
{
    private string _label;

    public LanguageChoice(UiLanguagePreference preference, string label)
    {
        Preference = preference;
        _label = label;
    }

    /// <summary>Persisted preference behind this choice.</summary>
    public UiLanguagePreference Preference { get; }

    /// <summary>Localized label shown in the ComboBox (and in the closed box).</summary>
    public string Label
    {
        get => _label;
        private set
        {
            if (string.Equals(_label, value, StringComparison.Ordinal))
            {
                return;
            }
            _label = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Label)));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Re-localize for the given tag without touching the choice identity.</summary>
    public void RefreshLabel(string tag) => Label = LanguageCatalog.DisplayName(Preference, tag);
}

/// <summary>Builds and refreshes the Settings language dropdown without replacing its items.</summary>
public static class LanguageChoices
{
    /// <summary>One choice per preference, in the persisted-catalog order (System first).</summary>
    public static List<LanguageChoice> Create(string tag) =>
        LanguageCatalog.AllPreferences
            .Select(preference => new LanguageChoice(preference, LanguageCatalog.DisplayName(preference, tag)))
            .ToList();

    /// <summary>
    /// Re-localize every label in place. The selected <see cref="LanguageChoice"/> instance
    /// survives a language switch, so the ComboBox keeps showing the current language.
    /// </summary>
    public static void RefreshLabels(IEnumerable<LanguageChoice> choices, string tag)
    {
        foreach (var choice in choices)
        {
            choice.RefreshLabel(tag);
        }
    }
}
