#!/bin/bash

set -eu

: ${DATAPATH:=.}
: ${CHANGELOG:=CHANGELOG}
: ${VERSION:=VERSION}
: ${DEV:=dev}

function main {

  # defaults and constants
  local line script_name
  local -r DONE="[ done ]" SKIPPED="[ skipped ]" FAILED="[ failed ]"
  script_name="gf"

  # process options
  if ! line=$(
    getopt -n "$0" \
           -o ivh\? \
           -l init,version,help\
           -- "$@"
  )
  then return 1; fi
  eval set -- "$line"

  function err {
    echo "$(basename "${0}")[error]: $@" >&2
    return 1
  }

  function git_status_empty {
    [[ -z "$(git status --porcelain)" ]] && return 0
    err "Uncommited changes" || return 1
  }

  # make git checkout return only error to stderr
  function git_checkout {
    local out
    out="$(git checkout $@ 2>&1)" \
      || err "$out" || return 1
  }

  function git_branch {
    git_checkout $1 2>/dev/null && return 0
    echo -n "Creating branch '$1': "
    git_checkout -b $1 || return 1
    echo $DONE
  }

  function git_branch_exists {
    git rev-parse --verify "$1" >/dev/null 2>&1
  }

  function git_repo_exists {
    [[ -d .git ]]
  }

  function git_branch_match {
    [[ "$( git rev-parse $1 )" == "$( git rev-parse $2 )" ]]
  }

  function confirm {
    echo -n "${@:-"Are you sure?"} [$(locale yesstr)/$(locale nostr)] "
    read
    [[ "$REPLY" =~ $(locale yesexpr) ]]
  }

  function gf_check {
    git_repo_exists \
      || err "Git repository does not exist" \
      || return 2
    { git_branch_exists "$DEV" && git_branch_exists master; } \
      || err "Missing branches '$DEV' or master" \
      || return 2
    git_status_empty \
      || return 1
    [[ -f "$VERSION" && -f "$CHANGELOG" ]] \
      || err "Missing working files" \
      || return 2
    [[ "$(cat "$VERSION")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || err "Invalid '$VERSION' file content format" \
      || return 1
  }

  # Current branch:
  #
  #  $DEV
  #   - increment minor version, set patch to 0
  #   - create release-major.minor branch
  #
  #  master, stable (major.minor, eg. 1.10)
  #   - increment patch version
  #   - create hotfix-major.minor.patch branch
  #
  #  hotfix-x or release-x; alias current
  #   - merge current branch into $DEV
  #   - merge current branch into stable
  #   - merge current branch into master (if matches stable)
  #   - create tag
  #   - delete current branch
  #
  #  feature
  #   - update version history
  #   - merge feature branch into $DEV
  #   - delete feature branch
  function gf_run {

    # set variables
    local curbranch major minor patch tag master into_master create_stable
    create_stable=1
    into_master=1
    curbranch=$(git rev-parse --abbrev-ref HEAD)
    tag=""
    IFS=. read major minor patch < "$VERSION"
    master=${major}.$minor

    # proceed
    case ${curbranch%-*} in

      HEAD)
        err "No branch detected on current HEAD" || return 1
        ;;

      "$DEV"|master|$master)
        local branch code header
        # set branch name and increment version
        branch="hotfix-${master}.$((++patch))"
        [[ $curbranch == "$DEV" ]] \
          && branch="release-${major}.$((++minor))" \
          && patch=0
        [[ $patch == 0 ]] \
          && { confirm "* Create release branch from branch '$DEV'?" || return 0; } \
          || { confirm "* Create hotfix?" || return 0; }
        [[ $curbranch == master ]] \
          && { git_branch $master || return 1; }
        # create a new branch
        git_branch_exists $branch \
          && { err "Destination branch '$branch' already exists" || return 1; }
        git_branch $branch || return 1
        # updating CHANGELOG and VERSION files
        if [[ $curbranch == "$DEV" ]]; then
          echo -n "Updating '$CHANGELOG' and '$VERSION' files: "
          header="${major}.${minor} | $(date "+%Y-%m-%d")" || return 1
          printf '\n%s\n\n%s\n' "$header" "$(<$CHANGELOG)" > "$CHANGELOG" || return 1
        else
          echo -n "Updating '$VERSION' file: "
        fi
        echo ${major}.${minor}.$patch > "$VERSION" || return 1
        git commit -am "$branch" >/dev/null || return 1
        if [[ $curbranch == "$DEV" ]]; then
          git_checkout "$DEV" \
          && git merge --no-ff $branch >/dev/null \
          && git_checkout $branch \
          || return 1
        fi
        echo $DONE
        ;;

      hotfix)
        confirm "* Merge hotfix?" || return 0
        tag=${master}.$patch
        git_branch_exists $master \
          && { git_branch_match master $master || into_master=0; }
        ;&

      release)
        [[ -z "$tag" ]] \
          && { confirm "* Create stable branch from release?" \
            || { create_stable=0; confirm "* Merge branch release into branch '$DEV'?" || return 0; } \
          } \
          && tag=${master}.0 \
        ;&

      *)
        # feature
        if [[ -z "$tag" ]]; then
          local commits
          commits="$(git log "$DEV"..$curbranch --pretty=format:"#   %s")"
          [[ -n $commits ]] \
            || err "Nothing to merge - feature branch '$curbranch' is empty" \
            || return 1
          confirm "* Merge feature '$curbranch'?" || return 0
          local tmpfile
          [[ -n "$(git log $curbranch.."$DEV")" ]] \
            && echo -n "Rebasing feature branch to '$DEV': " \
            && { git rebase "$DEV" >/dev/null || return 1; } \
            && echo $DONE
          # message for $CHANGELOG
          echo -n "Updating changelog: "
          tmpfile="$(mktemp)"
          {
            echo -e "\n# Please enter the feature description for '$CHANGELOG'. Lines starting"
            echo -e "# with # and empty lines will be ignored."
            echo -e "#\n# Commits of '$curbranch':\n#"
            echo -e "$commits"
            echo -e "#"
          } >> "$tmpfile"
          "${EDITOR:-vi}" "$tmpfile"
          sed -i '/^\s*\(#\|$\)/d;/^\s+/d' "$tmpfile"
          if [[ -n "$(cat "$tmpfile")" ]]; then
            cat "$CHANGELOG" >> "$tmpfile" || return 1
            mv "$tmpfile" "$CHANGELOG" || return 1
            git commit -am "Version history updated" >/dev/null || return 1
            echo $DONE
          else
            echo $SKIPPED
          fi
        fi
        # merge into $DEV
        echo -n "Merging into branch '$DEV': "
        git_checkout "$DEV" \
          && git merge --no-ff $curbranch >/dev/null \
          || return 1
        echo $DONE
        # merge release|hotfix branch into stable
        if [[ -n "$tag" && $create_stable == 1 ]]; then
          echo -n "Merging into stable branch '$master': " \
          && git_checkout master \
          && git_branch $master >/dev/null \
          && git merge --no-ff $curbranch >/dev/null \
          && echo $DONE \
          && echo -n "Creating tag '$tag': " \
          && git tag $tag >/dev/null \
          && echo $DONE \
          || return 1
          # merge stable branch into master
          if [[ $into_master == 1 ]]; then
            echo -n "Merging into master: " \
            && git_checkout master \
            && git merge $master >/dev/null \
            && echo $DONE \
            || return 1
          fi
        fi
        # delete branch, including remote
        [[ $create_stable == 0 ]] && { git_checkout $curbranch; return $?; }
        echo -n "Deleting branch '$curbranch': "
        git branch -r | grep origin/$curbranch$ >/dev/null \
          && { git push origin :refs/heads/$curbranch >/dev/null || return 1; }
        git branch -d $curbranch >/dev/null || return 1
        echo $DONE
    esac
  }

  # Prepare enviroment for gf:
  # - create $VERSION and $CHANGELOG file
  # - create $DEV branch
  function gf_init {
    # init git repo
    echo -n "Initializing git repository: "
    git_repo_exists \
      && { git_branch master || return 1; } \
      || { git init >/dev/null || return 1; }
    git_status_empty || return 1
    echo $DONE
    # VERSION and CHANGELOG files
    echo -n "Initializing '$VERSION' and '$CHANGELOG' files: "
    [[ ! -f "$VERSION" ]] \
      && { echo 0.0.0 > "$VERSION" || return 1; }
    [[ ! -f "$CHANGELOG" ]] \
      && { echo "$CHANGELOG created" > "$CHANGELOG" || return 1; }
    git add "$VERSION" "$CHANGELOG" >/dev/null \
      && git commit -m "Init version and changelog files" >/dev/null \
      || return 1
    echo $DONE
    # create and checkout $DEV branch
    git_branch "$DEV"
  }

  function gf_help {
    local help_file bwhite nc
    nc=$'\e[m'
    bwhite=$'\e[1;37m'
    help_file="$DATAPATH/${script_name}.help"
    [ -f "$help_file" ] || err "Help file not found" || return 1
    cat "$help_file" | fmt -w $(tput cols) \
    | sed "s/\(^\| \)\(--\?[a-zA-Z]\+\|$script_name\|^[A-Z].\+\)/\1\\$bwhite\2\\$nc/g"
  }

  function gf_version {
    local version
    version="$DATAPATH/VERSION"
    [ -f "$version" ] || err "Version file not found" || return 1
    echo -n "GNU gf "
    cat "$version"
  }

  # load user options
  while [ $# -gt 0 ]; do
      case $1 in
     -i|--init) gf_init; return $? ;;
     -v|--version) gf_version; return $? ;;
     -h|-\?|--help) gf_help; return $? ;;
      --) shift; break ;;
      *-) echo "$0: Unrecognized option '$1'" >&2; return 1 ;;
       *) break ;;
    esac
  done

  # run gf
  gf_check && gf_run

}

main "$@"