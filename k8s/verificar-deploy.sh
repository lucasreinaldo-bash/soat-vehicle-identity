#!/usr/bin/env bash
# Verificação pós-deploy no cluster, executada pelo pipeline de CD.
#
# Só leitura: confere o contrato que a API de vendas consome (emissor, chaves,
# papéis, audiência) sem cadastrar usuários a cada deploy. O teste completo,
# com cadastro, é o scripts/smoke-test.sh, que roda no CI.
set -euo pipefail

NS="vehicle-identity"
PORTA=18180
REALM="vehicle-sales"
ISSUER_ESPERADO="http://localhost:8180/realms/$REALM"

ok=0; falhas=0
passou(){ echo "  ✓ $1"; ok=$((ok+1)); }
falhou(){ echo "  ✗ $1"; falhas=$((falhas+1)); }
confere(){ [ "$2" = "$3" ] && passou "$1" || falhou "$1 (obtido '$2', esperado '$3')"; }
claims(){ python3 -c 'import sys,json,base64
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p))))' "$1"; }

kubectl -n "$NS" port-forward svc/keycloak "$PORTA:8080" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
BASE="http://localhost:$PORTA"
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/realms/$REALM")" = "200" ] && break
  sleep 1
done

echo "== Pods"
for d in identity-db keycloak; do
  R=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')
  confere "$d pronto" "$R" "1/1"
done

echo "== Contrato com a API de vendas"
confere "emissor estável" "$(curl -s "$BASE/realms/$REALM/.well-known/openid-configuration" | jq -r .issuer)" "$ISSUER_ESPERADO"
N=$(curl -s "$BASE/realms/$REALM/protocol/openid-connect/certs" | jq '[.keys[] | select(.use=="sig")] | length')
[ "${N:-0}" -ge 1 ] && passou "JWKS publica chave de assinatura" || falhou "JWKS sem chave de assinatura"
T=$(curl -s -X POST "$BASE/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=vehicle-sales-cli \
  -d username=admin@revenda.com -d password=admin12345 | jq -r '.access_token // empty')
if [ -n "$T" ]; then
  C=$(claims "$T")
  echo "$C" | jq -e '.realm_access.roles | index("admin")' >/dev/null && passou "operador tem o papel admin" || falhou "operador sem admin"
  echo "$C" | jq -e '.realm_access.roles | index("customer") | not' >/dev/null && passou "operador NÃO tem o papel customer" || falhou "operador com customer"
  echo "$C" | jq -e '(.aud | if type=="array" then . else [.] end) | index("vehicle-sales-api")' >/dev/null && passou "audiência inclui vehicle-sales-api" || falhou "audiência incorreta"
  confere "iss do token" "$(echo "$C" | jq -r .iss)" "$ISSUER_ESPERADO"
else
  falhou "token do operador não emitido"
fi

echo
echo "Resultado: $ok aprovados, $falhas falhas"
[ "$falhas" -eq 0 ]
