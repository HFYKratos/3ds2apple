using ThreeDsTwoApple.Launcher.Core.Localization;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Regression tests for the Settings language dropdown: after a language switch the box
/// must keep showing a language name (it used to go blank because the item list was
/// rebuilt and Avalonia dropped the selected item).
/// </summary>
public sealed class LanguageChoiceTests
{
    [Fact]
    public void CreatesOneChoicePerPreferenceWithANonBlankLabel()
    {
        var choices = LanguageChoices.Create(LanguageCatalog.EnglishTag);

        Assert.Equal(LanguageCatalog.AllPreferences, choices.Select(choice => choice.Preference));
        Assert.All(choices, choice => Assert.False(string.IsNullOrWhiteSpace(choice.Label)));
        Assert.Equal("English", choices[1].Label);
        Assert.Equal("简体中文", choices[2].Label);
    }

    [Fact]
    public void SwitchingLanguageRefreshesLabelsInPlaceSoTheSelectionSurvives()
    {
        var choices = LanguageChoices.Create(LanguageCatalog.EnglishTag);
        var selected = choices[2];

        LanguageChoices.RefreshLabels(choices, LanguageCatalog.ChineseSimplifiedTag);

        // The SAME item object stays selected: a rebuilt ComboBox item would be a new instance.
        Assert.Same(selected, choices[2]);
        Assert.Equal(UiLanguagePreference.SimplifiedChinese, selected.Preference);
        Assert.Equal("简体中文", selected.Label);
        // The "System" choice is the one label that follows the active UI language.
        Assert.Contains("简体中文", choices[0].Label);
        Assert.All(choices, choice => Assert.False(string.IsNullOrWhiteSpace(choice.Label)));
    }

    [Fact]
    public void RefreshingALabelRaisesPropertyChangedOnlyWhenItActuallyChanges()
    {
        var choices = LanguageChoices.Create(LanguageCatalog.EnglishTag);
        // Only the "System" entry follows the active UI language; English stays "English".
        var system = choices[0];
        var raised = new List<string?>();
        system.PropertyChanged += (_, args) => raised.Add(args.PropertyName);

        LanguageChoices.RefreshLabels(choices, LanguageCatalog.ChineseSimplifiedTag);
        Assert.Contains(nameof(LanguageChoice.Label), raised);

        raised.Clear();
        LanguageChoices.RefreshLabels(choices, LanguageCatalog.ChineseSimplifiedTag);
        Assert.Empty(raised);
    }
}
