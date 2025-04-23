#!/bin/bash

declare IS_VERBOSE=$1
declare SSH_DIR="$HOME/.ssh"
declare KEYS_LOC="$SSH_DIR/keys.txt"
#SHOULD_LOAD_KEYS_AGAIN=false
declare CURRENT_KEYS_COUNT=0

log() {
    # echo "$IS_VERBOSE"
    if [ "-v" = "$IS_VERBOSE" ] || [ "--verbose" = "$IS_VERBOSE" ]; then
        echo "$1"
    fi
}

#update the keys.txt file
update_keys_file() {
    log "Finding the private key files and updating the keys.txt..."
    find . -type f \( ! -name "known*" -a ! -name "*pub" -a ! -name "config*" ! -name "*.*" \) -exec ls -og1 {} + | sed -e 's/^\.\///' >keys.txt
    log "keys.txt successfully updated..."
    #CURRENT_KEYS_COUNT=$(cat .ssh/keys.txt | wc -l)
}

delete_keys_from_agent() {
    ssh-add -D -q >/dev/null
}

add_keys_to_agent() {
    while IFS= read -r line; do
        log "$line"
        ssh-agent -s >/dev/null
        ssh-add --apple-use-keychain -q "$line" >/dev/null
    done <"$KEYS_LOC"
}

main() {
    log "in main"
    cd "$SSH_DIR" || return
    log "Updating keys.txt"
    update_keys_file
    CURRENT_KEYS_COUNT=$(ssh-add -L | wc -l)
    log "$CURRENT_KEYS_COUNT"
    t2=$(wc -l "$KEYS_LOC" | awk {'print $1'})
    log "$t2"
    if [ "$CURRENT_KEYS_COUNT" -ne "$t2" ]; then
        log "loading keys"
        delete_keys_from_agent
        add_keys_to_agent
    fi
}

main

#[ `ssh-add -L | awk {'print $3'} | wc -l` -eq `cat ./.ssh/keys.txt| wc -l` ]
# check_keys_exist_in_agent() {

# }
# find "$SSH_DIR" -type f \( \( -name "gi*" -o -name "bi*" \) -a ! -name "*pub" \) -exec ls -og1 {} + | sed -e 's/^\.\///' >keys.txt
# find . -type f \( \( -name "gi*" -o -name "bi*" \) -a ! -name "*pub" \) -exec ls -og1 {} + | sed -e 's/^\.\///' >keys.txt
