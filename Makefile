deploy-common:
	DEPLOY_ENVIRONMENT=common pipenv run runway deploy
deploy-dev:
	DEPLOY_ENVIRONMENT=dev pipenv run runway deploy

deploy-prod:
	DEPLOY_ENVIRONMENT=prod pipenv run runway deploy
