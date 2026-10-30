# Serviço de Identidade — Plataforma de Revenda de Veículos

Serviço responsável pelo **registro e pela autorização dos compradores** da plataforma de revenda
de veículos (Tech Challenge Fase 3 — SOAT PósTech). Implementado com **Keycloak 26** sobre
**PostgreSQL**, expondo **OpenID Connect / OAuth 2.0** com tokens **JWT**.

---

## Por que este serviço é separado

O enunciado exige que o registro e a autorização de compradores sejam feitos "de forma separada,
para garantir que os dados de clientes estejam separados dos dados transacionais", e que o serviço
esteja "totalmente apartado do resto da solução".

Um módulo de autenticação dentro da API de vendas não atenderia: ele compartilharia processo,
banco e ciclo de deploy com os dados transacionais. Por isso a separação aqui é física:

| | Serviço de identidade (este repositório) | API de vendas ([soat-vehicle-sales](https://github.com/lucasreinaldo-bash/soat-vehicle-sales)) |
|---|---|---|
| Processo | Keycloak | NestJS |
| Banco de dados | PostgreSQL próprio (`identity-db`) | PostgreSQL próprio |
| Dados que guarda | Nome, e-mail, **CPF**, senha (hash) | Veículos e compras |
| Como identifica o cliente | É a fonte da identidade | Apenas pelo `sub` do token — um identificador opaco |
| Repositório e deploy | Próprios | Próprios |

**Nenhum dado pessoal atravessa a fronteira.** O CPF é atributo do cliente e vive apenas aqui; ele
não aparece nem no token JWT — o teste de fumaça verifica isso a cada PR. A API de vendas recebe só
o `sub` e os papéis.

```
                       ┌──────────────────────────────┐
  Cliente ─cadastro──▶ │  SERVIÇO DE IDENTIDADE       │──▶ identity-db
          ─login─────▶ │  Keycloak · realm            │    nome, e-mail, CPF, senha
                       │  vehicle-sales               │
                       └──────────────┬───────────────┘
                                      │ JWT assinado (RS256)
                                      │ sub · papéis · aud
                                      ▼
  Cliente ─Bearer────▶ ┌──────────────────────────────┐
                       │  API DE VENDAS               │──▶ banco próprio
                       │  valida o JWT pelo JWKS      │    veículos, compras (só o sub)
                       └──────────────────────────────┘
```

---

## O realm `vehicle-sales`

Toda a configuração está versionada em [`realm/vehicle-sales-realm.json`](realm/vehicle-sales-realm.json)
e é importada na inicialização. Nada é configurado manualmente pelo console.

### Papéis

| Papel | Quem tem | O que permite na API de vendas |
|---|---|---|
| `customer` | **Todo cliente que se cadastra** — atribuído automaticamente pelo papel padrão do realm | Comprar veículos e consultar as próprias compras |
| `admin` | O operador da revenda — **e apenas ele**: o operador não recebe `customer` | Cadastrar e editar veículos |

As listagens de veículos à venda e vendidos são públicas e não exigem token.

O papel `admin` existe porque a Fase 3 restringe a compra a pessoas cadastradas. Se qualquer
cliente cadastrado pudesse também cadastrar e editar veículos, o controle de acesso não protegeria
nada. Separar operador e comprador é uma inferência de modelagem.

A separação vale nos dois sentidos. O papel padrão do realm (`default-roles-vehicle-sales`) inclui
`customer`, e o Keycloak expande esse papel composto dentro do token. Se o operador o recebesse, o
token dele traria `customer` e ele conseguiria comprar pela API. Por isso o usuário operador é
importado com `realmRoles: ["admin"]` apenas — e o teste de fumaça verifica isso.

### Clients

| Client | Tipo | Fluxo | Para quê |
|---|---|---|---|
| `vehicle-sales-frontend` | Público | Authorization Code + **PKCE** | Aplicação web do time de frontend: login e cadastro de clientes |
| `vehicle-sales-cli` | Público | Senha (*Direct Access Grant*) | **Somente desenvolvimento, testes automatizados e demonstração** |

Os dois incluem `vehicle-sales-api` na audiência (`aud`) do token. Assim a API de vendas pode
recusar tokens emitidos para outras aplicações.

### Cadastro do cliente

O cadastro é self-service pela tela de registro do Keycloak, em português, com os campos nome,
sobrenome, e-mail, **CPF** e senha. A política de senha exige no mínimo 8 caracteres, diferentes
do usuário, e a proteção contra força bruta bloqueia a conta temporariamente após 5 tentativas erradas.

### Usuário de demonstração

O realm cria um operador para a demonstração: **`admin@revenda.com`** / **`admin12345`**, com o
papel `admin`. Clientes não são pré-cadastrados — o cadastro faz parte do fluxo demonstrado.

---

## Como executar localmente

Requisito: Docker com o plugin Compose.

```bash
docker compose up
```

O comando sobe o PostgreSQL do serviço e o Keycloak, que importa o realm automaticamente. Ao
terminar, ficam disponíveis:

| O quê | Endereço |
|---|---|
| Cadastro de cliente | http://localhost:8180/realms/vehicle-sales/account — clique em **Cadastre-se** |
| Console de administração | http://localhost:8180/admin — usuário `admin`, senha `admin` |
| Descoberta OpenID Connect | http://localhost:8180/realms/vehicle-sales/.well-known/openid-configuration |
| Chaves públicas (JWKS) | http://localhost:8180/realms/vehicle-sales/protocol/openid-connect/certs |

Os valores padrão podem ser sobrescritos a partir de [`.env.example`](.env.example).

### Obtendo um token

O token do operador é obtido assim:

```bash
curl -s -X POST http://localhost:8180/realms/vehicle-sales/protocol/openid-connect/token \
  -d grant_type=password -d client_id=vehicle-sales-cli \
  -d username=admin@revenda.com -d password=admin12345 | jq -r .access_token
```

Para um cliente, troque usuário e senha pelos usados no cadastro. Para inspecionar o conteúdo, cole
o token em https://jwt.io.

---

## O contrato com a API de vendas

A API de vendas não conhece o Keycloak; conhece apenas este contrato:

| Item | Valor |
|---|---|
| Emissor (`iss`) | `http://localhost:8180/realms/vehicle-sales` |
| Chaves públicas (JWKS) | `<emissor>/protocol/openid-connect/certs` |
| Algoritmo | RS256 |
| Audiência (`aud`) | contém `vehicle-sales-api` |
| Identificador do cliente | `sub` |
| Papéis | `realm_access.roles` |

### O detalhe do emissor estável

O Keycloak escreve no `iss` o endereço pelo qual foi acessado. O navegador o acessa por
`localhost:8180`; a API, dentro do Docker, por `keycloak:8080`. Sem tratamento, o mesmo serviço
emitiria tokens com emissores diferentes, e a API rejeitaria parte deles.

A configuração `KC_HOSTNAME` fixa o emissor, e `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` deixa os serviços
internos continuarem usando o nome da rede Docker. O resultado foi verificado: um token pedido por
`keycloak:8080`, de dentro da rede, sai com `iss` igual a `http://localhost:8180/realms/vehicle-sales`.

### Como a API de vendas se conecta

O compose cria a rede Docker **`vehicle-identity`**, com nome fixo. A API de vendas se conecta a
ela para buscar as chaves públicas em `http://keycloak:8080/realms/vehicle-sales/protocol/openid-connect/certs`.
É a única coisa que os dois serviços compartilham — nenhum banco, nenhum dado.

Por isso, localmente, **este serviço sobe antes** da API de vendas.

> **Recriou este serviço?** Um `docker compose down` remove a rede `vehicle-identity`, e o
> `up` cria outra, com um identificador novo. O container da API continua apontando para a rede
> antiga e não sobe (`network ... not found`). Recrie-o, na pasta da API:
> `docker compose up -d --force-recreate api`.

---

## Como testar

Com o serviço no ar:

```bash
./scripts/smoke-test.sh
```

O script valida o contrato de ponta a ponta:

| Verificação | O que garante |
|---|---|
| Emissor estável e JWKS publicado | A API consegue validar a assinatura |
| Operador com papel `admin` e audiência correta | O controle de acesso da API funciona |
| **Operador sem o papel `customer`** | **O operador não consegue comprar veículos** |
| Cadastro de cliente com CPF válido | O fluxo de registro funciona |
| CPF fora do formato rejeitado | O perfil de usuário valida o atributo |
| Cliente novo recebe `customer`, e não recebe `admin` | O papel padrão está correto |
| **CPF ausente do token** | **Nenhum dado pessoal vaza para a API de vendas** |
| Senha errada não gera token | A autenticação recusa credencial inválida |

O mesmo script roda no CI a cada Pull Request, contra um Keycloak real.

---

## Implantação em Kubernetes

Os manifestos estão em [`k8s/`](k8s/), no namespace próprio `vehicle-identity`, separado do
namespace da API de vendas:

| Arquivo | Recursos | Papel |
|---|---|---|
| `00-namespace.yaml` | Namespace `vehicle-identity` | Isolamento do serviço de identidade |
| `01-configmap.yaml` | ConfigMap | Banco, hostname fixo do emissor, health checks |
| `02-secret.yaml` | Secret | Senha do banco e credencial do console de administração |
| `03-postgres.yaml` | PVC + Deployment + Service | Banco **próprio** da identidade, só interno (ClusterIP) |
| `04-keycloak.yaml` | Deployment + Service | Keycloak com o realm importado e probes na porta de gerenciamento |

O realm não é copiado para um manifesto. O `deploy.sh` gera o ConfigMap `vehicle-sales-realm` a
partir de [`realm/vehicle-sales-realm.json`](realm/vehicle-sales-realm.json), o mesmo arquivo
que o Docker Compose usa. A configuração tem uma fonte só.

```bash
minikube start
./k8s/deploy.sh
kubectl -n vehicle-identity port-forward svc/keycloak 8180:8080
```

Com o port-forward em `8180`, os endereços da seção
[Como executar localmente](#como-executar-localmente) continuam válidos, e o emissor do token
continua `http://localhost:8180/realms/vehicle-sales`. Dentro do cluster, a API de vendas busca
as chaves em `keycloak.vehicle-identity.svc.cluster.local:8080`.

Decisões dos manifestos:

- **Rollout determinado pela configuração.** O pod do Keycloak leva uma anotação com o hash do
  ConfigMap, do Secret e do realm. Configuração nova reinicia o pod; um deploy sem mudança não
  reinicia nada.
- **`startupProbe` generosa.** A primeira subida cria o schema e importa o realm, e leva mais
  tempo. A liveness continua rígida depois disso.
- **Estratégia `Recreate`.** Em modo de desenvolvimento, duas instâncias do Keycloak não formam
  cluster. A nova só sobe depois de a antiga parar.

Para remover tudo: `./k8s/cleanup.sh`.

---

## Fluxo de mudanças: Pull Requests, CI e deploy automatizado

Toda mudança entra por **Pull Request** e chega ao cluster sem passo manual.

A branch `main` é protegida, inclusive para administradores:

- não aceita push direto;
- exige histórico linear;
- só aceita merge com o CI verde.

### CI: a cada Pull Request

O CI está em [`.github/workflows/ci.yml`](.github/workflows/ci.yml) e tem dois jobs:

- **Validação da configuração**: o realm é JSON válido e declara os papéis e clients esperados; o
  compose e os manifestos Kubernetes são válidos.
- **Testes de fumaça do Keycloak**: sobe o serviço e executa `scripts/smoke-test.sh`.

### CD: a cada merge na `main`

O CD está em [`.github/workflows/cd.yml`](.github/workflows/cd.yml). Ele dispara quando o CI
termina com sucesso na `main` e roda num **runner self-hosted**, na máquina que hospeda o
minikube, com o rótulo `minikube`. O job:

1. faz checkout do commit que passou no CI;
2. executa `k8s/deploy.sh` e espera o rollout;
3. executa [`k8s/verificar-deploy.sh`](k8s/verificar-deploy.sh), que confere os pods prontos, o
   emissor estável, o JWKS e os papéis e a audiência do token do operador.

A verificação só lê dados e não cadastra usuários a cada deploy.

O runner não executa código de Pull Request:

- o CD só dispara depois do merge;
- PRs de contribuidores externos exigem aprovação antes de qualquer workflow rodar;
- o environment `minikube` só aceita deploys a partir de branch protegida.

---

## Decisões e limitações conhecidas

**Keycloak em vez de um serviço próprio.** Autenticação é uma área em que implementar do zero
acumula riscos (armazenamento de senha, proteção contra força bruta, rotação de chaves, fluxos OAuth).
O Keycloak entrega tudo isso pronto, é auto-hospedado e não depende de conta externa nem de custo,
diferente de Cognito ou Auth0.

**CPF validado apenas pelo formato.** O perfil declarativo do Keycloak valida o formato (11
dígitos), mas não tem validador nativo de dígito verificador nem de unicidade de atributo. As duas
validações exigiriam uma extensão Java (SPI) do Keycloak — fora do escopo desta fase.

**Senha do operador e client de senha.** A senha do `admin@revenda.com` versionada no realm e o
client `vehicle-sales-cli`, com o grant de senha, existem **apenas para desenvolvimento, testes e
demonstração**. Em produção, o operador seria criado com credencial vinda de um cofre de segredos, e
o client de senha não existiria — o OAuth 2.1 desaconselha o grant de senha.

**Modo de desenvolvimento.** O compose usa `start-dev` (HTTP, sem cache de temas), adequado ao
ambiente local.
