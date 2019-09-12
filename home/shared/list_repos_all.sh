#!/bin/bash

{
    /home/shared/list_repos.sh
    /home/shared/list_repos_legacy.sh
} | sort
