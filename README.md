# project-pull-mover

Script to change the status of a pull request in a GitHub project.

## How to use

Install the [`gh` command line tool](https://cli.github.com/).

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

```sh
bundle install
./project_pull_mover.rb
```

Follow instructions about required options and run suggested `gh auth` commands to get the right permissions, e.g.,

```sh
error: your authentication token is missing required scopes [project]
To request it, run:  gh auth refresh -s project
```
