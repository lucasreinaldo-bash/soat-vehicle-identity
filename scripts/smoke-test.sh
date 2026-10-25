#!/usr/bin/env bash
# Testes de fumaça do serviço de identidade. Valida o CONTRATO que a API de
# vendas consome: emissor estável, audiência, papéis e ausência de dados
# pessoais no token. Uso: ./scripts/smoke-test.sh (com o compose no ar)
set -euo pipefail

BASE="${KC_URL:-http://localhost:8180}"
REALM="vehicle-sales"
ISSUER_ESPERADO="${KC_ISSUER:-http://localhost:8180/realms/$REALM}"
ADMIN_USER="${KC_ADMIN_USER:-admin}"
ADMIN_PASS="${KC_ADMIN_PASSWORD:-admin}"

ok=0; falhas=0
passou(){ echo "  ✓ $1"; ok=$((ok+1)); }
falhou(){ echo "  ✗ $1"; falhas=$((falhas+1)); }
claims(){ python3 -c 'import sys,json,base64
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p))))' "$1"; }
token_de(){ curl -s -X POST "$BASE/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=vehicle-sales-cli \
  --data-urlencode "username=$1" --data-urlencode "password=$2" | jq -r '.access_token // empty'; }

echo "== 1. Descoberta OIDC"
ISS=$(curl -s "$BASE/realms/$REALM/.well-known/openid-configuration" | jq -r .issuer)
[ "$ISS" = "$ISSUER_ESPERADO" ] && passou "issuer estável: $ISS" || falhou "issuer '$ISS' (esperado '$ISSUER_ESPERADO')"
JWKS=$(curl -s "$BASE/realms/$REALM/protocol/openid-connect/certs" | jq '[.keys[] | select(.use=="sig")] | length')
[ "${JWKS:-0}" -ge 1 ] && passou "JWKS publica $JWKS chave(s) de assinatura" || falhou "JWKS sem chaves de assinatura"

echo "== 2. Operador da revenda (seed)"
T=$(token_de "admin@revenda.com" "admin12345")
if [ -n "$T" ]; then
  C=$(claims "$T")
  echo "$C" | jq -e '.realm_access.roles | index("admin")' >/dev/null && passou "admin@revenda.com tem o papel admin" || falhou "admin sem papel admin"
  echo "$C" | jq -e '(.aud | if type=="array" then . else [.] end) | index("vehicle-sales-api")' >/dev/null && passou "audiência inclui vehicle-sales-api" || falhou "audiência sem vehicle-sales-api"
  [ "$(echo "$C" | jq -r .iss)" = "$ISSUER_ESPERADO" ] && passou "iss do token confere com o emissor" || falhou "iss do token divergente"
else falhou "não obteve token do operador"; fi

echo "== 3. Cadastro de cliente"
MT=$(curl -s -X POST "$BASE/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS" | jq -r .access_token)
EMAIL="cliente.$(date +%s)$RANDOM@teste.com"
cria(){ curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $MT" -H 'Content-Type: application/json' -d "$1"; }
COD=$(cria "{\"username\":\"$EMAIL\",\"email\":\"$EMAIL\",\"firstName\":\"Maria\",\"lastName\":\"Silva\",\"enabled\":true,\"emailVerified\":true,\"attributes\":{\"cpf\":[\"52998224725\"]},\"credentials\":[{\"type\":\"password\",\"value\":\"senha12345\",\"temporary\":false}]}")
[ "$COD" = "201" ] && passou "cliente cadastrado (HTTP 201)" || falhou "cadastro do cliente retornou HTTP $COD"
COD=$(cria "{\"username\":\"x$EMAIL\",\"email\":\"x$EMAIL\",\"firstName\":\"Joao\",\"lastName\":\"Souza\",\"enabled\":true,\"attributes\":{\"cpf\":[\"123\"]}}")
[ "$COD" = "400" ] && passou "CPF fora do formato é rejeitado (HTTP 400)" || falhou "CPF inválido aceito (HTTP $COD)"

echo "== 4. Token do cliente"
T=$(token_de "$EMAIL" "senha12345")
if [ -n "$T" ]; then
  C=$(claims "$T")
  echo "$C" | jq -e '.realm_access.roles | index("customer")' >/dev/null && passou "cliente novo recebe o papel customer por padrão" || falhou "cliente sem papel customer"
  echo "$C" | jq -e '.realm_access.roles | index("admin") | not' >/dev/null && passou "cliente NÃO tem o papel admin" || falhou "cliente recebeu admin"
  echo "$C" | jq -e 'has("cpf") | not' >/dev/null && passou "CPF não aparece no token (dado pessoal fica só aqui)" || falhou "CPF vazou para o token"
  [ -n "$(echo "$C" | jq -r '.sub // empty')" ] && passou "token traz o identificador opaco (sub)" || falhou "token sem sub"
else falhou "não obteve token do cliente"; fi

echo "== 5. Credencial inválida"
[ -z "$(token_de "$EMAIL" "senha-errada")" ] && passou "senha errada não gera token" || falhou "senha errada gerou token"

echo
echo "Resultado: $ok aprovados, $falhas falhas"
[ "$falhas" -eq 0 ]
