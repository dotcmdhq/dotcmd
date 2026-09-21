param($Adapter)
$ErrorActionPreference = 'Stop'
. $Adapter
function Check($Line, $Expected) {
    $actual = (TabExpansion2 $Line $Line.Length).CompletionMatches.CompletionText -join '|'
    if ($actual -cne $Expected) { throw "Unexpected completions for ${Line}: $actual (expected $Expected)" }
}
Check './.cmd b' 'build-docs'
Check './.cmd docs --mode=d' '--mode=debug'
Check './.cmd docs --mode "two w' "'two words'"
Check './.cmd docs --mode hé' 'héllo'
Check './.cmd empty no-such-completion' ''
$line = './.cmd docs --directory two'
$matches = (TabExpansion2 $line $line.Length).CompletionMatches
if ($matches.Count -ne 1 -or $matches[0].ResultType -ne 'ProviderContainer') { throw 'Directory filtering failed' }
Check '& "./.cmd" docs --mode d' 'debug'

Check './.cmd docs --mode two` w' "'two words'"
Check './.cmd docs --mode="two w' "'--mode=two words'"
$line = './.cmd docs --mode debug'
$actual = (TabExpansion2 $line ($line.Length - 4)).CompletionMatches.CompletionText -join '|'
if ($actual -cne 'debug') { throw "Completion in the middle of a word failed: $actual" }
