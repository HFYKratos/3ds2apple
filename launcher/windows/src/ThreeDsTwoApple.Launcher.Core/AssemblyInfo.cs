using System.Runtime.CompilerServices;

// The unit-test project exercises parser/hash helpers that stay internal to the
// launcher library (they are not part of a public API).
[assembly: InternalsVisibleTo("ThreeDsTwoApple.Launcher.Core.Tests")]
