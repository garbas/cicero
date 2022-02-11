{ ... }:

{
  inputs.github-event = ''
    "github-event": {
      action: "push"
      deleted: false
      ref: "refs/heads/\(repository.default_branch)"
      repository: {
        name: string
        owner: login: string
        default_branch: string
        clone_url: string
      }
      head_commit: {
        id: string
        distinct: true
      }
    }
  '';

  output = { github-event }:
    let inherit (github-event.value.github-event) repository head_commit; in
    {
      success."${repository.name}/ci".start = {
        inherit (repository) clone_url;
        sha = head_commit.id;
        statuses_url = "https://api.github.com/repos/${repository.owner.login}/${repository.name}/statuses/${head_commit.id}";
      };
    };
}
