Replace YOURUSER with your Docker Hub username (not email). Keep the token in your terminal only.

1. Create a Hub token
Hub → Account Settings → Personal access tokens → Read & Write.

2. Export credentials (this shell only)

cd /home/drupal-wsl/redhat/ubi10-apache-php
export DOCKERHUB_USER=YOURUSER
export DOCKERHUB_TOKEN=dckr_pat_your_token

3. Confirm names (no network)

make push PUSH_DRY_RUN=1

You should see:

--> Remote  docker.io/YOURUSER/ubi10-apache-php
--> Tags    1.0.0 1.0 latest

4. Build, test, push

make build test
make push

make push logs in via stdin (token is not printed) and pushes:

• docker.io/YOURUSER/ubi10-apache-php:1.0.0 ← pin this
• docker.io/YOURUSER/ubi10-apache-php:1.0
• docker.io/YOURUSER/ubi10-apache-php:latest

5. Check the Hub page

https://hub.docker.com/r/YOURUSER/ubi10-apache-php