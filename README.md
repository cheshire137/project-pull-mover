# project-pull-mover

Script to change the status of a pull request in a GitHub project. On macOS, when the script is run and any pull
requests have their project status changed, a desktop notification will appear with the count of how many PRs were
moved.

## How to use

### Prerequisites

Install the [`gh` command line tool](https://cli.github.com/). `gh` will be used to authenticate with the GitHub API.
You'll also need [Ruby](https://www.ruby-lang.org/en/documentation/installation/) installed; I built this script
with Ruby version 2.7.1p83.

In [GraphiQL](https://docs.github.com/en/graphql/overview/explorer), run a GraphQL query like this one to get IDs for the options in your project's "Status"-like column:

```graphql
query {
  organization(login: "yourOrg") {
    projectV2(number: 123) { # e.g., https://github.com/orgs/yourOrg/projects/123
      field(name: "Status") { ... on ProjectV2SingleSelectField { options { name id } } }
    }
  }
}
```

You'll use the option IDs from the GraphQL query to tell project_pull_mover where to move your pull requests in your
project.

### Options

```sh
Usage: ./project_pull_mover.rb [options]
    -p, --project-number NUM         Project number (required), e.g., 123 for https://github.com/orgs/someorg/projects/123
    -o, --project-owner OWNER        Project owner login (required), e.g., someorg for https://github.com/orgs/someorg/projects/123
    -t, --project-owner-type TYPE    Project owner type (required), either 'user' or 'organization'
    -s, --status-field STATUS        Status field name (required), name of a single-select field in the project
    -i, --in-progress ID             Option ID of 'In progress' column for status field
    -a, --not-against-main ID        Option ID of 'Not against main' column for status field
    -n, --needs-review ID            Option ID of 'Needs review' column for status field
    -r, --ready-to-deploy ID         Option ID of 'Ready to deploy' column for status field
    -c, --conflicting ID             Option ID of 'Conflicting' column for status field
    -g, --ignored IDS                Optional comma-separated list of option IDs of columns like 'Blocked' or 'On hold' for status field
    -q, --quiet                      Quiet mode, suppressing all output except errors
```

Run the script with:

```sh
./project_pull_mover.rb
```

Follow instructions about required options and run suggested `gh auth` commands to get the right permissions, e.g.,

```sh
error: your authentication token is missing required scopes [project]
To request it, run:  gh auth refresh -s project
```

Example use:

```sh
./project_pull_mover.rb -p 123 -o myOrg -t organization -i 123abc -a zyx987 -n ab123cd -r a1b2c3 -c z9y8x7 -g "idkfa1,iddqd2" -s "Status"
```

### Example output

Example no-op output:

```sh
⏳ Authenticating with GitHub...
✅ Authenticated as GitHub user @cheshire137
ℹ️ 'Status' options enabled: In progress, Not against main, Needs review, Ready to deploy, Conflicting, Ignored
⏳ Looking up items in project 123 owned by @myOrg...
✅ Found 20 pull requests in project
ℹ️ Found pull requests in 4 unique repositories by @someRepoOwner
⏳ Looking up more info about each pull request in project...
✅ Loaded extra pull request info
ℹ️ No pull requests needed a different status
```

Example output when some pull requests had the wrong 'Status':

```sh
⏳ Authenticating with GitHub...
✅ Authenticated as GitHub user @cheshire137
⏳ Looking up items in project 123 owned by @myOrg...
✅ Found 20 pull requests in project
ℹ️ Found pull requests in 4 unique repositories by @someRepoOwner
⏳ Looking up more info about each pull request in project...
✅ Loaded extra pull request info
⏳ Moving someRepoOwner/repo1#330751 out of In progress ✏️ column to 'Conflicting'...
⏳ Moving someRepoOwner/repo2#335443 out of In progress ✏️ column to 'Conflicting'...
⏳ Moving someRepoOwner/repo2#337389 out of In progress ✏️ column to 'Conflicting'...
ℹ️ Updated status for 3 pull requests
```

## Automatic runs with cron

Make a directory for holding logs from the script. Here is an example config for crontab:

```sh
# Runs every 30 minutes, Monday through Friday, between 9am and 5pm:
*/31,*/1 9-17 * * 1-5 /path/to/this/repo/project_pull_mover.rb -p 123 -o myOrg -t organization -i 123abc -a zyx987 -n ab123cd -r a1b2c3 -c z9y8x7 -g "idkfa1,iddqd2" -s "Status" -q >/path/to/your/log/directory/stdout.log 2>/path/to/your/log/directory/stderr.log
```
