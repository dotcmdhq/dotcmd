source "$1"
check() {
    local LC_ALL=C
    COMP_LINE=$1 COMP_POINT=${#1}
    _dotcmd_complete ./.cmd
    [[ "${COMPREPLY[*]}" == "$2" ]] || { printf '%s\n' "$1"; declare -p COMPREPLY; exit 1; }
}
check './.cmd b' 'build-docs '
check './.cmd docs --mode=d' 'debug '
check './.cmd docs "--mode=d' '--mode=debug'
check './.cmd docs --mode="d' 'debug'
check './.cmd docs --mode "two w' 'two words'
check './.cmd docs --mode two" w' ' words'
check "./.cmd docs --mode two' w" ' words'
check './.cmd docs --mode=two" w' ' words'
check './.cmd docs --mode "two "w' 'two\ words '
check './.cmd docs --mode hé' 'héllo '
check './.cmd docs --directory two' 'two\ dirs/'
check './.cmd docs --file=two\ f' 'two\ files.txt '
check './.cmd docs --file=two" f' ' files.txt'
check './.cmd empty ' ''
