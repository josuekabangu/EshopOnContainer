#!/usr/bin/env bash
# Génère helm/values/<service>.yaml à partir des manifestes de kubernetes/ (migration vers Helm, une fois)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# encrypted <service> : recopie le bloc encryptedData du SealedSecret, réindenté sous encryptedData:
encrypted() {
  echo "encryptedData:"
  sed -n '/encryptedData:/,/template:/p' "kubernetes/$1/sealedsecret-$1.yaml" | sed '1d;$d' | sed 's/^    /  /'
}

{ cat <<'EOF'
# Identity.API (docs/03-kubernetes/07-identity-api.md)
image:
  repository: ghcr.io/josuekabangu/identity-api
  tag: 87e28f8

port: 5223

route:
  enabled: true
  hostname: identity.eshop.lab

env:
  - name: ASPNETCORE_HTTP_PORTS
    value: "5223"
  # Adresses publiques des clients, par le point d'entrée : lues au démarrage
  - name: WebAppClient
    value: http://shop.eshop.lab
  - name: WebhooksWebClient
    value: http://webhooks.eshop.lab

EOF
  encrypted identity-api; } > helm/values/identity-api.yaml

{ cat <<'EOF'
# Basket.API (docs/03-kubernetes/09-basket-api.md)
image:
  repository: ghcr.io/josuekabangu/basket-api
  tag: 87e28f8

# gRPC en HTTP/2 seul sur 8080 ; second port, en HTTP/1.1, réservé aux probes
portName: grpc
probePort: 8081

service:
  enabled: true
  # HTTP/2 sans chiffrement : indication pour le point d'entrée
  appProtocol: kubernetes.io/h2c

waitForRabbitMQ: true

env:
  - name: Identity__Url
    value: http://identity.eshop.lab
  - name: Kestrel__Endpoints__grpc__Url
    value: http://+:8080
  - name: Kestrel__Endpoints__grpc__Protocols
    value: Http2
  - name: Kestrel__Endpoints__health__Url
    value: http://+:8081
  - name: Kestrel__Endpoints__health__Protocols
    value: Http1

EOF
  encrypted basket-api; } > helm/values/basket-api.yaml

for s in ordering-api webhooks-api; do
  { cat <<EOF
# ${s} (docs/03-kubernetes)
image:
  repository: ghcr.io/josuekabangu/${s}
  tag: 87e28f8

waitForRabbitMQ: true

env:
  - name: Identity__Url
    value: http://identity.eshop.lab

EOF
    encrypted "$s"; } > "helm/values/${s}.yaml"
done

for s in order-processor payment-processor; do
  { cat <<EOF
# ${s} : tâche de fond, sans Service ; une seule copie (docs/03-kubernetes)
image:
  repository: ghcr.io/josuekabangu/${s}
  tag: 87e28f8

service:
  enabled: false

waitForRabbitMQ: true

EOF
    encrypted "$s"; } > "helm/values/${s}.yaml"
done

{ cat <<'EOF'
# WebApp (docs/03-kubernetes/15-webapp.md) ; une seule copie : clés de protection des données propres au pod
image:
  repository: ghcr.io/josuekabangu/webapp
  tag: 87e28f8

route:
  enabled: true
  hostname: shop.eshop.lab

waitForRabbitMQ: true

env:
  - name: IdentityUrl
    value: http://identity.eshop.lab
  - name: CallBackUrl
    value: http://shop.eshop.lab
  - name: services__catalog-api__http__0
    value: http://catalog-api:8080
  - name: services__basket-api__http__0
    value: http://basket-api:8080
  - name: services__ordering-api__http__0
    value: http://ordering-api:8080
  # Connexion en HTTP par un nom autre que localhost (adaptation 72ee8fa)
  - name: Authentication__AllowInsecureCookies
    value: "true"

EOF
  encrypted webapp; } > helm/values/webapp.yaml

cat > helm/values/webhook-client.yaml <<'EOF'
# WebhookClient (docs/03-kubernetes/16-webhook-client.md) ; aucun secret
image:
  repository: ghcr.io/josuekabangu/webhook-client
  tag: a6647c9

route:
  enabled: true
  hostname: webhooks.eshop.lab

env:
  - name: IdentityUrl
    value: http://identity.eshop.lab
  - name: CallBackUrl
    value: http://webhooks.eshop.lab
  # Adresse à laquelle Webhooks.API livre les notifications : interne au cluster
  - name: WebhookClientOptions__SelfUrl
    value: http://webhook-client:8080/
  - name: services__webhooks-api__http__0
    value: http://webhooks-api:8080
  # Connexion en HTTP par un nom autre que localhost (adaptation a6647c9)
  - name: Authentication__AllowInsecureCookies
    value: "true"
EOF

ls helm/values/
