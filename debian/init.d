#! /bin/sh

grep -qs boot=casper /proc/cmdline || exit 0

# Try to cache everything we're likely to need after ejecting.  This
# is fragile and simple-minded, but our options are limited.
cache_path() {
    path="$1"

    if [ -d "$path" ]; then
        find "$path" -type f | xargs cat > /dev/null 2>&1
    elif [ -f "$path" ]; then
        if [ -x "$path" ]; then
            if file "$path" | grep -q 'dynamically linked'; then
                for lib in $(ldd "$path" | awk '{ print $3 }'); do
                    cache_path "$lib"
                done
            fi
        fi
        cat "$path" >/dev/null 2>&1
    fi
}

for path in $(which halt) $(which reboot) /etc/rc?.d /etc/default; do
    cache_path "$path"
done

eject -p -m /cdrom >/dev/null 2>&1

# XXX - i18n
echo -n "Please remove the disc, close the tray (if any) and press ENTER: "
if [ -x /sbin/usplash_write ]; then
    /sbin/usplash_write "TIMEOUT 0"
    /sbin/usplash_write "TEXT Please remove the disc, close the tray (if any)"
    /sbin/usplash_write "TEXT and press ENTER to continue"
fi

read x < /dev/console

exit 0