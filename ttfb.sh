#!/bin/bash
set -eu

function help() {
    tput setaf 2
    echo "Usage ./ttfb.sh -f <file> [-a] [-l] [-i] | -h"

    tput setaf 3
    echo "Options:"
    echo -e "-u \t Single URL. Overwrites the -f option."
    echo -e "-f \t Path to the file with URLs."
    echo -e "-l \t Limit of the URLs to read from the file."
    echo -e "-r \t Reads random rows from the file."
    echo -e "-a \t Overwrites the default user-agent."
    echo -e "-i \t [Flag] Attempt to invalidate cache by adding a timestamp to the URLs."
    echo -e "-h \t [Flag] Help."

    exit 0
}

if [[ ! $* =~ ^\-.+ ]]; then
    help
fi

while getopts "f:u:l:a::rih" opt; do
    case "$opt" in
    f) file=${OPTARG} ;;
    a) user_agent="${OPTARG}" ;;
    l) limit=${OPTARG} ;;
    i) invalidate_cache=1 ;;
    r) random=1 ;;
    h) help ;;
    *) help ;;
    esac
done

if [[ -z ${user_agent+set} ]]; then
    user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.0.0 Safari/537.36"
fi

if [[ -z ${invalidate_cache+set} ]]; then
    invalidate_cache=0
fi

if [[ -z ${random+set} ]]; then
    random=0
fi

function send_request() {
    curl -H "user-agent: $2" \
        --silent \
        -o /dev/null \
        -w "%{time_starttransfer} %{http_code} %{time_pretransfer} %{time_connect} %{time_namelookup}\n" \
        "$1"
}

function prepare_url() {
    url=$1

    if [[ $2 -gt 0 ]]; then
        if [[ "$url" == *"?"* ]]; then
            url="$url&$(date +%s)"
        else
            url="$url?$(date +%s)"
        fi
    fi

    echo "$url"
}

if [[ -z ${limit+set} ]]; then
    limit=0
fi

if [[ ! -f $file ]]; then
    echo "File '$file' not found"
    exit 1
fi

time_total=0
server_time_total=0
visited_counter=0
non_200_counter=0
latency_time_total=0

printf "\n"

function visit_url() {
    ((visited_counter+=1))

    url="$(prepare_url "$1" $invalidate_cache)"

    read -r time_starttransfer http_code time_pretransfer time_connect time_namelookup <<<"$(send_request "$url" "$user_agent")"
    if [[ $http_code != '200' ]]; then
        non_200_counter=$((non_200_counter + 1))
        echo "$visited_counter" "$http_code" "$url" -
    else
        server_time=$(awk "BEGIN {print $time_starttransfer-$time_pretransfer; exit}")
        server_time_total=$(awk "BEGIN {print $server_time_total+$server_time; exit}")
        latency_time=$(awk "BEGIN {print $time_connect-$time_namelookup; exit}")
        latency_time_total=$(awk "BEGIN {print $latency_time_total+$latency_time; exit}")
        time_total=$(awk "BEGIN {print $time_total+$time_starttransfer; exit}")
        server_time_average=$(awk "BEGIN {print $server_time_total/($visited_counter-$non_200_counter); exit}")
        echo "$visited_counter" "$http_code" "$url" "$time_starttransfer" "$server_time" "$server_time_average"
    fi
}

if [[ $random == 1 ]]; then
    random_rows=()
    while IFS= read -r row ; do random_rows+=("$row"); done <<< "$(
    awk -v loop=$limit -v range="$(wc -l "$file")" 'BEGIN {
            srand()
            do {
                numb = 1 + int(rand() * range)
                if (!(numb in prev)) {
                   print numb
                   prev[numb] = 1
                   count++
                }
            } while (count<loop)
        }'
    )"

    for row in "${random_rows[@]}"
    do
        in=$(awk "NR==$row{ print; exit }" "$file")
        visit_url "$in"
    done
else
    while read -r in || [ -n "$in" ]; do
        [ -z "$in" ] && continue
        
        visit_url "$in"

        if [[ $limit -gt 0 && $visited_counter -ge $limit ]]; then
            break
        fi
    done <"$file"
fi

printf "\n"

pages_evaluated=$(awk "BEGIN {print $visited_counter-$non_200_counter; exit}")
latency_time_average=$(awk "BEGIN {print $latency_time_total/$pages_evaluated; exit}")
server_time_average=$(awk "BEGIN {print $server_time_total/$pages_evaluated; exit}")

echo "Pages visited:                  $((visited_counter))"
echo "Pages evaluated:                $((visited_counter - non_200_counter))"
echo "Pages skipped:                  $non_200_counter"
echo "Total time elapsed:             $time_total s"
echo "Avg TTFB:                       $(awk "BEGIN {print ($time_total/$pages_evaluated) * 1000; exit}") ms"
echo "Avg server time with latency:   $(awk "BEGIN {print $server_time_average * 1000; exit}") ms"
echo "Avg network latency:            $(awk "BEGIN {print $latency_time_average * 1000; exit}") ms"
echo "Avg server time minus latency:  $(awk "BEGIN {print ($server_time_average - $latency_time_average*2) * 1000; exit}") ms"
