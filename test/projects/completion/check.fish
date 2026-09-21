source $argv[1]
function check
    set -l actual (complete -C "$argv[1]" | string replace -r '\t.*$' '')
    set -l joined (string join '|' -- $actual)
    if test "$joined" != "$argv[2]"
        printf 'Unexpected completions for %s: %s\n' "$argv[1]" "$actual" >&2
        exit 1
    end
end
check './.cmd b' build-docs
check './.cmd docs --mode=d' --mode=debug
check './.cmd docs --mode "two w' 'two words'
check './.cmd docs --mode hé' héllo
check './.cmd docs --directory two' 'two dirs/'
check './.cmd docs --file=two\\ f' '--file=two files.txt'
check './.cmd empty ' ''

check './.cmd docs --directory ~/tar' '~/target-dir/'
check './.cmd docs --file ~/tar' '~/target-dir/|~/target-file.txt'
check './.cmd docs --file=$HOME/tar' '--file=$HOME/target-dir/|--file=$HOME/target-file.txt'
check './.cmd docs --file=~/tar' '--file=~/target-dir/|--file=~/target-file.txt'
