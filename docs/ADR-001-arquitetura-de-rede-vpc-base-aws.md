# ADR-001: Arquitetura de rede base na AWS (VPC 10.0.0.0/26, 4 subnets `/28` em 2 AZs, NAT Gateway único)

**Status:** Aprovado para implementação
**Data:** 2026-07-25
**Última revisão:** 2026-07-26 (revisão 4 — ver Histórico de revisões)
**Autor:** Agente Arquiteto
**Aprovado por:** beuren33
**Data da aprovação:** 2026-07-25

> Estados possíveis: `Proposto` → `Aprovado para implementação` |
> `Rejeitado` | `Substituído por ADR-XXX`
> Somente um humano altera este campo. O agente sempre cria como `Proposto`.

> **⚠ Nota da revisão 4 (não altera o campo `Status` acima — apenas um humano pode
> fazê-lo):** esta revisão muda a decisão de **backend do Terraform**, de local para
> remoto (Seção 4, Anexo A.1 — nova Etapa 0). A aprovação registrada em 2026-07-25 foi
> dada sobre o desenho **com state local**. A mudança de backend é substancial o
> suficiente — afeta como todo `apply` subsequente é executado — para exigir
> **confirmação humana explícita antes do próximo `apply`**, mesmo que o `Status` geral
> do ADR já esteja "Aprovado para implementação". Recomenda-se que o humano responsável
> registre essa confirmação (ex.: comentário de PR ou atualização deste cabeçalho)
> antes de rodar a Etapa 0 do Anexo A.1.

## Histórico de revisões

| Rev | Data | O que mudou | Origem |
|---|---|---|---|
| 1 | 2026-07-25 | Versão inicial: VPC `/24`, 4 subnets `/26` em 2 AZs, 1 NAT Gateway | Requisitos iniciais do usuário |
| 2 | 2026-07-25 | VPC passa a `/26`; desenho passa a **1 AZ** com 2 subnets `/27`; backend remoto de state **removido do escopo**; respostas às perguntas A.5.2, A.5.3, A.5.4, A.5.5 e A.5.6 incorporadas | Respostas do usuário às perguntas abertas |
| 3 | 2026-07-25 | **Volta a 2 AZs (`az-a` e `az-b`)**, resolvendo a pergunta bloqueante A.5.2 da revisão 2; subnets passam a **4 × `/28`** dentro do mesmo `/26`; **correção factual**: `/27` para subnet de ALB é *recomendação* documentada, não mínimo rejeitado pela API (ver Fontes consultadas); Opção B (NAT por AZ) volta a ser aplicável e é reavaliada; custo cross-AZ volta à Seção 7 e aos riscos; ALB e RDS deixam de estar bloqueados | Resposta do usuário à pergunta bloqueante da revisão 2 |
| 4 | 2026-07-26 | **Backend do Terraform passa de local para remoto**: bucket S3 `gitops-terraformcode33` (`us-east-1`, já provisionado pelo usuário fora deste módulo), com **lock nativo do S3** (`use_lockfile`, não DynamoDB) — verificado via MCP AWS e MCP Terraform. Bucket confirmado com SSE-S3 habilitada e Public Access Block total; **versionamento desabilitado** (gap registrado como nova dívida, menor que a anterior). Seções 1 (ressalva 1.3), 2 (premissa 11), 4 (Decisão), 5 (Consequências), 6 (Riscos), 7 (IAM e Backup/DR) e Anexo A (A.1 nova Etapa 0, A.3.1/A.3.2, A.4, A.5) atualizados. Condição de reversão 3 é executada preventivamente | Pedido explícito do usuário — bucket de backend já provisionado |

> Todas as revisões foram feitas **antes de qualquer aprovação, exceto a revisão 4**, que
> foi feita **depois** da aprovação humana de 2026-07-25 sobre o desenho de rede. A
> mudança de backend introduzida na revisão 4 é sinalizada no cabeçalho como pendente de
> confirmação humana específica antes do próximo `apply` — o agente não alterou e não
> altera o campo `Status`.

---

## 1. Contexto

O repositório `gitops-workshop-dvn` é o ambiente prático do workshop **DevOps na Nuvem**.
Hoje ele contém apenas duas aplicações containerizadas (`dvn-workshop-apps/backend/YoutubeLiveApp`,
em .NET, e `dvn-workshop-apps/frontend/youtube-live-app`, em Next.js), ambas com `Dockerfile`.
Não existe nenhum código de infraestrutura (`.tf`) nem qualquer recurso de rede provisionado.
Este é o **primeiro ADR do projeto** e também o primeiro documento em `docs/`.

Para que qualquer workload (ECS, EKS, EC2, RDS, load balancers) possa ser implantado, é
preciso antes definir a fundação de rede: uma VPC com segmentação pública/privada, saída
para a internet e roteamento explícito.

**Requisitos funcionais declarados pelo usuário (consolidados até a revisão 3, com uma
mudança na revisão 4):**

- VPC com CIDR `10.0.0.0/26`.
- **Duas Availability Zones**, referidas aqui como "AZ-a" e "AZ-b" (as duas primeiras
  retornadas pelo data source de AZs disponíveis da região alvo).
- **4 subnets**: 1 pública e 1 privada em cada AZ.
- Internet Gateway para as subnets públicas.
- **Um único NAT Gateway**, como decisão explícita de custo sobre disponibilidade.
- ~~Sem backend remoto de state do Terraform nesta entrega~~ — **substituído na
  revisão 4:** o usuário provisionou um bucket S3 (`gitops-terraformcode33`, já
  existente) e solicitou explicitamente sua adoção como backend remoto de state, com
  mecanismo de lock. Ver Seção 4.
- Prefixo de projeto para nomenclatura e tagging: `dvn`. Ambiente: `dev`.
- O ambiente **será destruído fora do horário de uso**.

**Requisitos não funcionais inferidos do contexto (ver Premissas):**

- Ambiente de aprendizado/workshop, com forte sensibilidade a custo.
- Time pequeno, operação não 24x7.
- Infraestrutura descartável e recriável a partir de código.

### Ressalvas técnicas que o arquiteto registra explicitamente (Guardrail 4)

Três pontos precisam ficar registrados como **dívidas conscientes**, não como boas práticas.
Nenhum deles impede a entrega do workshop, mas todos fecham portas de forma irreversível ou
custosa:

**1.1 — O `/26` de VPC é extremamente pequeno e não é redimensionável.**
Um `/26` tem 64 endereços **para a VPC inteira**. O CIDR primário de uma VPC não pode ser
alterado nem removido depois de criada; só é possível **adicionar** CIDRs secundários (quota
padrão de 5 blocos IPv4 por VPC, ajustável até 50 — verificado), e subnets IPv4 nunca mudam
de tamanho após criadas. Isso significa que o plano de endereçamento decidido aqui é
definitivo para esta VPC. A recomendação técnica continua sendo um `/16` (ou no mínimo um
`/20`) com subnets `/24`. Esta ressalva **agrava-se na revisão 3**: dividir o mesmo `/26` em
4 subnets em vez de 2 leva cada subnet a `/28`, ou seja, **11 IPs utilizáveis cada**.

**1.2 — Subnets `/28` ficam abaixo da recomendação documentada da AWS para ALB.**
A documentação do Elastic Load Balancing recomenda que cada subnet de ALB tenha **bitmask de
pelo menos `/27` e ao menos 8 IPs livres**, para permitir escala horizontal do load balancer.
O que a API efetivamente rejeita é a **falta de 8 IPs livres**, não o bitmask em si: um `/28`
com 11 utilizáveis atende os 8 livres no momento da criação. Ou seja, **ALB é criável em
subnets `/28`, mas o desenho fica na margem** e perde a folga de escala que a AWS pede.
Isso corrige uma imprecisão da revisão 2, que tratava `/27` como mínimo rejeitado pela API
(ver Fontes consultadas). O trade-off completo está na sub-decisão de endereçamento da
Seção 3.

**1.3 — Ausência de backend remoto de state contradiz a prática A.3.1.**
Foi decidido pelo usuário operar com state local nesta entrega. As consequências estão
registradas na Seção 5 e na Seção 6. É uma dívida assumida explicitamente pelo usuário,
não uma omissão do agente.

> **Resolvido (parcialmente) na revisão 4:** o usuário provisionou um bucket S3
> (`gitops-terraformcode33`, `us-east-1`) e pediu explicitamente sua adoção como backend
> remoto. A dívida original — state local, sem locking, sem compartilhamento — **deixa de
> existir**. Uma ressalva **nova e menor** a substitui: o bucket, verificado via MCP AWS
> nesta revisão (`get-bucket-versioning`), está com **versionamento desabilitado**. Sem
> versionamento, o backend ganha locking e compartilhamento, mas ainda não oferece
> recuperação de uma versão anterior de um state corrompido ou truncado. A prática A.3.1
> passa a estar **quase**, não totalmente, satisfeita (ver Seção 4, Seção 5, Seção 6 e
> A.5, pergunta 4).

> **Resolvido na revisão 3:** a ressalva 1.2 da revisão 2 — "AZ única bloqueia ALB e RDS" —
> **deixa de existir**. Com 2 AZs, ALB e RDS voltam a ser provisionáveis nesta VPC, dentro
> das limitações de endereçamento descritas acima.

## 2. Premissas

Se qualquer uma destas premissas estiver errada, este ADR deve ser revisado antes da
implementação:

1. **Região:** `us-east-1`. Não foi informada pelo usuário. Assumida por ser a região
   padrão da maioria dos workshops e a de menor custo. As decisões aqui são
   region-agnostic; apenas os nomes de AZ mudam. **Continua em aberto (A.5.1).** Nota da
   revisão 4: o bucket de backend `gitops-terraformcode33`, confirmado via MCP AWS, está
   em `us-east-1` — reforço indireto de que essa é a região alvo, mas não substitui
   confirmação explícita do usuário.
2. **AZs:** as **duas primeiras retornadas pelo data source de AZs disponíveis** da região
   alvo (referidas no documento como "AZ-a" e "AZ-b"). Nomes de AZ não são hardcoded —
   "az-a"/"az-b" são convenção de nomenclatura, não os literais `us-east-1a`/`us-east-1b`.
3. **Tamanho das subnets:** não foi especificado pelo usuário. Assumido `/28` para cada uma
   das quatro subnets, consumindo o `/26` inteiro. Justificativa e alternativas descartadas
   na Seção 3 (sub-decisão de endereçamento).
4. **Escala:** baixa. Poucas dezenas de IPs no total, tráfego de saída na ordem de poucas
   dezenas de GB/mês. Se ALB for usado, assume-se **1 nó por AZ** (carga de workshop), sem
   escala horizontal do load balancer.
5. **Orçamento:** sensível a custo. O ambiente **será** destruído fora do horário de uso
   (confirmado pelo usuário).
6. **Compliance:** nenhum requisito regulatório (PCI, LGPD com dado sensível, HIPAA).
   Nenhuma exigência de isolamento de rede além de "workload privado não recebe conexão
   direta da internet".
7. **Conectividade híbrida:** não há necessidade de VPN, Direct Connect ou peering com
   outra VPC no momento.
8. **IPv6:** fora de escopo. A VPC será IPv4-only.
9. **RTO/RPO:** RTO de horas, RPO irrelevante (rede não tem estado; é recriável a partir
   do código Terraform).
10. **Conta AWS:** conta única, sem AWS Organizations / multi-account, sem VPC pré-existente
    a integrar.
11. **State do Terraform:** **remoto, em backend S3 com lock nativo do S3** (atualizado na
    revisão 4 — substitui a premissa original de state local, que era decisão explícita do
    usuário e foi revertida a pedido dele). O bucket `gitops-terraformcode33`
    (`us-east-1`) já existe e foi verificado via MCP AWS. Tecnicamente, múltiplos
    operadores/pipelines passam a poder aplicar mudanças com proteção de locking — mas
    **nenhuma mudança de processo foi solicitada** nesta revisão; a prática de "um
    operador por vez" permanece válida como convenção até decisão em contrário (ver A.5,
    pergunta 7).
12. **Nomenclatura:** prefixo de projeto `dvn`, ambiente `dev` (confirmados pelo usuário).
13. **Load balancer e banco de dados:** assume-se que **ALB e RDS podem vir a ser usados**
    (foi exatamente o motivo de voltar a 2 AZs). O desenho é dimensionado para permiti-los,
    não para suportá-los sob carga real.

## 3. Opções consideradas

Todas as opções compartilham a mesma base: 1 VPC `/26`, 2 subnets públicas e 2 subnets
privadas distribuídas em **duas AZs**, 1 Internet Gateway e route tables separadas para
público/privado. O que as diferencia é **como as subnets privadas alcançam a internet**.
A decisão de backend do Terraform (Seção 4) é ortogonal a este eixo e não afeta as opções
abaixo.

> **Nota de revisão 3:** na revisão 2, com AZ única, o eixo "NAT único vs. NAT por AZ" havia
> sido anulado e a Opção B marcada como não aplicável. Com o retorno a 2 AZs, **esse eixo
> volta a existir** e a Opção B é reavaliada de fato abaixo.

### Opção A — NAT Gateway único, na subnet pública da AZ-a (escolhida)

Um NAT Gateway gerenciado, provisionado na subnet pública da AZ-a, com um Elastic IP. **As
duas** subnets privadas usam a **mesma** route table privada, cuja rota `0.0.0.0/0` aponta
para esse NAT Gateway.

- **Prós**
  - Menor custo entre as opções com NAT gerenciado: um único custo fixo por hora e um
    único EIP.
  - Serviço gerenciado: sem patching, sem gestão de instância, escalabilidade automática
    de banda pela AWS.
  - Configuração mínima: 2 route tables no total, fácil de ensinar em workshop.
  - **Consome apenas 1 IP** do espaço de endereçamento (na subnet pública da AZ-a), o que
    importa muito num desenho de subnets `/28`.
- **Contras**
  - **SPOF de egress:** se a AZ-a falhar, a subnet privada da AZ-b perde saída para a
    internet mesmo estando saudável.
  - **Custo de transferência cross-AZ** para todo o tráfego originado na AZ-b, que precisa
    atravessar a fronteira de AZ até o NAT na AZ-a. Volta a existir na revisão 3.
  - Custo fixo por hora corre mesmo com tráfego zero.
- **Custo relativo:** baixo. Ordem de grandeza: dezenas de USD/mês (custo fixo por hora do
  NAT + custo por GB processado + cross-AZ + EIP). _Valores unitários não verificados._
- **Complexidade operacional:** baixa.

### Opção B — Um NAT Gateway por AZ (padrão de produção) — **volta a ser aplicável**

Dois NAT Gateways, um em cada subnet pública, dois EIPs e **duas** route tables privadas,
cada uma apontando para o NAT da sua própria AZ.

- **Prós**
  - Elimina o SPOF de egress: a falha de uma AZ não tira a saída da outra.
  - **Elimina o custo de transferência cross-AZ** do egress.
  - É o padrão recomendado para produção.
- **Contras**
  - **~2x o custo fixo por hora**, que é justamente o driver dominante da fatura desta
    arquitetura.
  - **Consome 2 IPs** (um por subnet pública `/28`), reduzindo de 10 para 10/10 os IPs
    livres em cada subnet pública — relevante porque a recomendação da AWS para ALB é de
    8 IPs livres por subnet; a margem cai para 2 IPs em cada uma.
  - Mais recursos e mais uma route table para explicar em aula, sem ganho pedagógico.
- **Custo relativo:** ~2x a Opção A no componente fixo.
- **Complexidade operacional:** baixa a média.

### Opção C — NAT Instance (EC2 fazendo NAT)

Uma instância EC2 pequena (ex.: família t4g) com IP forwarding e mascaramento, com
`source_dest_check` desabilitado, servindo como gateway de saída.

- **Prós**
  - Pode ser mais barata que o NAT Gateway em cenários de tráfego muito baixo,
    especialmente com instância Graviton pequena ou Spot.
  - Permite inspeção/customização de tráfego.
- **Contras**
  - **Não é gerenciada:** patching de SO, hardening, monitoramento e recuperação são
    responsabilidade do time.
  - Banda e conexões concorrentes limitadas pelo tipo da instância.
  - Continua sendo SPOF — sem ganho algum sobre a Opção A, com mais trabalho operacional.
  - **Consome IP da subnet pública**, que agora tem apenas 11 utilizáveis.
  - Distrai do objetivo pedagógico do workshop (que é GitOps, não administrar um roteador
    Linux).
- **Custo relativo:** potencialmente o mais baixo em USD, o mais alto em horas de pessoa.
- **Complexidade operacional:** alta.

### Opção D — Sem NAT (subnets privadas sem saída, egress via VPC Endpoints)

Nenhum NAT. As subnets privadas só acessam serviços AWS através de VPC Endpoints
(Gateway Endpoint para S3/DynamoDB, Interface Endpoints para ECR, Logs, SSM, etc.).

- **Prós**
  - Elimina completamente o custo por hora de NAT e reduz superfície de saída.
  - Postura de segurança mais forte: nenhum egress irrestrito para a internet.
- **Contras**
  - Quebra qualquer dependência de internet pública (repositórios de pacotes, Docker Hub,
    APIs de terceiros) — provável bloqueio para as aplicações do workshop.
  - **Cada Interface Endpoint consome uma ENI por AZ, ou seja, um IP por subnet** — com 11
    IPs utilizáveis por subnet e 2 AZs, dois ou três endpoints já comem a folga que o ALB
    precisaria.
  - Com 2 AZs, o custo por hora de cada Interface Endpoint é cobrado duas vezes; com vários
    serviços, o total pode superar o de um NAT único.
- **Custo relativo:** variável; baixo com poucos endpoints, alto com muitos.
- **Complexidade operacional:** média a alta (descobrir e mapear todos os endpoints
  necessários).

### Sub-decisão de endereçamento: como dividir o `/26` entre 4 subnets

Esta é a tensão central da revisão 3 e está registrada aqui de forma explícita.

**O fato verificado nesta sessão:** a AWS **recomenda** que cada subnet de Application Load
Balancer tenha bitmask de pelo menos `/27` **e** ao menos 8 IPs livres. A frase da
documentação é uma recomendação de dimensionamento para permitir escala ("to ensure that
your load balancer can scale properly, verify that…"), e o comportamento efetivamente
observado como erro é a **insuficiência de IPs livres** (menos de 8 livres na subnet). Não
há evidência documental de que a criação de um ALB seja **rejeitada** apenas por a subnet
ser `/28`. **Isso corrige a afirmação da revisão 2**, que descrevia `/27` como "bitmask
mínimo exigido".

**As divisões possíveis de um `/26` (64 endereços) para 4 subnets:**

| Divisão | Cabe no `/26`? | IPs utilizáveis por subnet | ALB viável? | RDS viável? | Avaliação |
|---|---|---|---|---|---|
| **4 × `/28`** (escolhida) | Sim, exato | 11 | Sim (≥8 livres), **abaixo da recomendação `/27`** | Sim | Única divisão que cabe e desbloqueia ALB + RDS |
| 4 × `/27` | **Não** — exigiria um `/25` | 27 | Sim, com folga | Sim | Tecnicamente superior, mas **viola o CIDR `/26` definido pelo usuário** |
| 2 × `/27` (1 pública + 1 privada) em 2 AZs | Sim | 27 | **Não** | **Não** | Ver nota abaixo — não resolve nada |
| 1 × `/27` + 2 × `/28` (3 subnets) | Sim | 27 / 11 | Só se houver 2 públicas | Só se houver 2 privadas | Sempre falta um par; bloqueia ALB **ou** RDS |
| `/26` primário + CIDR secundário | Sim, com 2º bloco | 27 (4 × `/27`) | Sim, com folga | Sim | Melhor saída técnica, mas adiciona um bloco não pedido |

**Nota sobre a hipótese de "2 subnets `/27` abrangendo múltiplas AZs":** essa alternativa
foi considerada e **é tecnicamente impossível**. Na AWS, **uma subnet pertence a exatamente
uma Availability Zone** — não existe subnet multi-AZ. Manter 2 subnets `/27` em 2 AZs
significaria, na prática, 1 subnet pública na AZ-a e 1 subnet privada na AZ-b (ou variação),
o que **não** satisfaz nem o ALB (precisa de 2 subnets públicas em AZs distintas) nem o DB
subnet group do RDS (precisa de 2 subnets em AZs distintas). Ou seja: essa hipótese não
entrega HA nem desbloqueia os serviços; ela é registrada apenas para deixar claro por que
foi descartada.

**Escolhida: 4 × `/28`.** Motivos:
1. É a **única** divisão que cabe no `/26` definido pelo usuário e ao mesmo tempo satisfaz
   as duas restrições duras verificadas: ALB exige 2 subnets em AZs distintas; DB subnet
   group exige subnets em ≥2 AZs.
2. `/28` é o **menor bitmask permitido** para subnet IPv4 na AWS (verificado) — está no
   limite, mas é legal.
3. Com 11 IPs utilizáveis, cada subnet pública atende o requisito prático de 8 IPs livres
   do ALB no momento da criação (10 livres na pública da AZ-a após o NAT; 11 na da AZ-b).
4. No perfil de carga assumido (workshop, 1 nó de ALB por AZ), a folga de escala que a
   recomendação `/27` protege **não será exercida**.

**Contrapartidas aceitas, registradas como dívida:**
- A divisão consome **todo** o `/26`. Não sobra espaço para nenhuma subnet adicional
  (dedicada a banco, a endpoints ou a uma terceira AZ).
- O desenho fica **abaixo da recomendação da AWS** para subnets de ALB. Se o ALB precisar
  escalar, a documentação alerta para 5xx e timeouts por falha de escala.
- A margem é de **2 a 3 IPs livres** por subnet pública depois de um ALB. Qualquer ENI extra
  (Interface Endpoint, segunda NAT, appliance) come essa margem.
- **Recomendação técnica do arquiteto (Guardrail 4):** o desenho correto para este conjunto
  de requisitos seria um `/25` (4 × `/27`) ou o `/26` primário acrescido de um CIDR
  secundário. A escolha por 4 × `/28` é uma acomodação à restrição de `/26`, não a melhor
  engenharia disponível. A saída futura é **adicionar um CIDR secundário** e migrar as
  subnets — o que significa recriar subnets, não redimensioná-las.

### Nota sobre uma quinta opção emergente

O provider AWS 6.56.0 expõe no recurso `aws_nat_gateway` o argumento `availability_mode`
com valor `regional` (NAT Gateway regional, multi-AZ, gerenciado pela AWS), verificado na
documentação do provider na revisão 1 deste ADR. Em tese isso ofereceria HA de egress sem
duplicar recursos manualmente — e, **com o retorno a 2 AZs na revisão 3, essa opção volta a
ser genuinamente relevante**: seria o caminho para eliminar o SPOF de egress e o custo
cross-AZ sem pagar dois NATs. Ainda assim, **não foi verificada** a disponibilidade
regional, o modelo de preço nem a maturidade dessa modalidade, e por isso ela **não é
recomendada aqui**. Fica registrada como candidata prioritária de reavaliação (condição de
reversão 5).

## 4. Decisão

**Escolhemos a Opção A — NAT Gateway único**, na subnet pública da AZ-a, com uma única route
table privada compartilhada pelas duas subnets privadas, sobre uma **VPC `10.0.0.0/26`
dividida em quatro subnets `/28` (2 públicas + 2 privadas) distribuídas em duas
Availability Zones**, e, **a partir da revisão 4, com backend remoto de state do Terraform**
(S3 + lock nativo do S3), **porque** o ambiente é um workshop com forte sensibilidade a
custo, operado por uma única pessoa por vez, que precisa apenas **poder** demonstrar ALB e
RDS — não sustentá-los sob carga —, **aceitando o custo** de que (a) o egress da AZ-b
depende da AZ-a e paga transferência cross-AZ, (b) o espaço de endereçamento fica esgotado,
irreversível e abaixo da recomendação da AWS para subnets de ALB, e (c) o state passa a ter
locking e compartilhamento, mas **ainda não tem versionamento** no bucket atualmente
provisionado — recuperação de uma versão anterior de um state corrompido continua pendente
até essa lacuna ser fechada (ver Seção 6).

O critério que desempatou entre A e B foi **custo × propósito pedagógico**: o NAT Gateway é
o item dominante da fatura, e duplicá-lo dobraria o principal driver de custo para comprar
uma disponibilidade que um ambiente destruído fora de uso não precisa. Um segundo fator
reforçou a escolha na revisão 3: com subnets `/28`, um segundo NAT **consumiria mais um IP
de subnet pública**, corroendo justamente a folga que o ALB precisa. A Opção C troca dólares
por trabalho operacional, não resolve o SPOF e consome IP escasso. A Opção D provavelmente
quebra as aplicações e multiplica o consumo de IPs por 2 AZs.

**Decisão de backend (revisão 4):** adota-se o backend `s3` nativo do Terraform, apontando
para o bucket `gitops-terraformcode33` (`us-east-1`, já provisionado fora deste
módulo/ADR), com **lock nativo do S3** (`use_lockfile = true`) em vez de DynamoDB,
**porque**:
- o lock nativo do S3 é o mecanismo **recomendado pela AWS** para backends S3 desde o
  Terraform 1.10.0, enquanto o lock via DynamoDB é tratado como **legado em depreciação**
  para esse fim — verificado via MCP AWS (AWS Prescriptive Guidance for Terraform);
- elimina um recurso adicional (tabela DynamoDB) e a permissão IAM associada a ela, sem
  perda de proteção para o padrão de uso deste workshop;
- não há hoje nenhuma tabela DynamoDB na conta (verificado via MCP AWS,
  `dynamodb list-tables`), então não há migração a considerar, apenas escolha inicial.

**Trade-off aceito:** o lock nativo do S3 exige **Terraform ≥ 1.10.0** em toda máquina ou
runner que rodar `plan`/`apply` sobre este backend — passa a ser um pré-requisito de
ambiente, registrado em A.3.2. O bucket em si **não é criado por este Terraform** (já
existe); a criação/gestão do bucket permanece fora de escopo (ver A.4).

**Componentes da decisão:**

| Componente | Definição |
|---|---|
| VPC | CIDR `10.0.0.0/26`, DNS support e DNS hostnames habilitados |
| Availability Zones | 2, as duas primeiras retornadas pelo data source de AZs disponíveis ("AZ-a" e "AZ-b") |
| Subnet pública AZ-a | `10.0.0.0/28` — 11 IPs utilizáveis (hospeda o NAT Gateway) |
| Subnet pública AZ-b | `10.0.0.16/28` — 11 IPs utilizáveis |
| Subnet privada AZ-a | `10.0.0.32/28` — 11 IPs utilizáveis |
| Subnet privada AZ-b | `10.0.0.48/28` — 11 IPs utilizáveis |
| Internet Gateway | 1, anexado à VPC |
| Elastic IP | 1, para o NAT Gateway |
| NAT Gateway | 1, público, na subnet pública da AZ-a |
| Route table pública | 1, com rota `0.0.0.0/0` → Internet Gateway, associada às **duas** subnets públicas |
| Route table privada | 1, com rota `0.0.0.0/0` → NAT Gateway, associada às **duas** subnets privadas |
| Atribuição de IP público automático | **Desabilitada** em todas as subnets (padrão `false`); IP público concedido explicitamente por recurso |
| Backend do Terraform | **Remoto (atualizado na revisão 4):** backend `s3`, bucket `gitops-terraformcode33` (`us-east-1`, já provisionado), `key` a definir por ambiente (ex.: `network/dev/terraform.tfstate` — ver A.5, pergunta 5), lock nativo do S3 (`use_lockfile = true`, requer Terraform ≥ 1.10.0). Ver Seções 5, 6 e 7 |
| Versionamento do bucket de state | **Desabilitado no bucket atual** — verificado via MCP AWS nesta revisão. Gap registrado, não corrigido por este ADR (ver Seção 6 e A.5, pergunta 4) |
| Criptografia do bucket de state | SSE-S3 (AES256) já habilitada no bucket, `bucket_key_enabled = true` — verificado via MCP AWS |
| Public Access Block do bucket de state | Já habilitado (bloqueio total de ACL e política pública) — verificado via MCP AWS |
| Prefixo de nomenclatura | Projeto `dvn`, ambiente `dev` |

Observação sobre a atribuição de IP público: manter `map_public_ip_on_launch` em `false` é
deliberado — uma subnet ser "pública" é uma propriedade da **rota**, não da atribuição
automática de IP. Isso evita expor instâncias por acidente.

Observação sobre o espaço livre: os quatro `/28` cobrem integralmente o `10.0.0.0/26`.
**Não há endereço sobrando** para uma quinta subnet.

Observação sobre as route tables: a decisão de manter **uma única route table privada** (e
não uma por AZ) é consequência direta da Opção A — com um só NAT, as duas subnets privadas
têm a mesma rota default. Se a Opção B for adotada no futuro, essa route table precisa ser
desdobrada em duas.

## 5. Consequências

### Positivas

- Fundação de rede mínima, legível e barata, suficiente para EC2/ECS, **ALB e RDS** no
  escopo do workshop.
- **ALB e RDS voltam a ser provisionáveis** nesta VPC — o bloqueio duro registrado na
  revisão 2 foi eliminado.
- Separação clara público/privado em duas AZs, que é o conceito que o workshop precisa
  demonstrar, agora com a topologia canônica (2 públicas + 2 privadas).
- Toda a rede é descartável e recriável por código — RTO de rede medido em minutos.
- ~~Sem bootstrap de backend: `terraform init` funciona imediatamente...~~ — **deixa de
  valer na revisão 4.** `terraform init` agora depende do bucket remoto (Etapa 0 do
  Anexo A.1) já existir e estar acessível — o que já é o caso, mas é uma dependência nova.
  Em troca, ganha-se: **locking real** contra `apply` concorrente (lock nativo do S3) e
  **compartilhamento** do state entre operadores/pipeline, sem exigir uma tabela DynamoDB
  adicional.
- Custo mensal previsível e dominado por um único item (o NAT Gateway), que continua sendo
  **um só** mesmo com 2 AZs. O custo do backend de state é desprezível (ver Seção 7).

### Negativas e dívidas assumidas

- **SPOF de egress:** se a AZ-a cair, a subnet privada da AZ-b fica sem saída para a
  internet, ainda que a própria AZ-b esteja saudável. O ambiente é multi-AZ na topologia,
  mas **não** no caminho de egress.
- **Custo de transferência cross-AZ** para todo tráfego de saída originado na AZ-b.
- **Subnets abaixo da recomendação da AWS para ALB:** `/28` com 11 IPs utilizáveis atende os
  8 livres na criação, mas não deixa a folga de escala que a documentação pede. Sob escala,
  a documentação alerta para 5xx/timeouts.
- **Espaço de endereçamento esgotado e irreversível:** 11 IPs utilizáveis por subnet, `/26`
  totalmente consumido, sem espaço para uma quinta subnet. Subnets não se redimensionam.
- **Dívida de state — atualizada na revisão 4 (atenuada, não eliminada):** com o backend S3
  + lock nativo adotado, os seguintes pontos da dívida original de state local **deixam de
  existir**:
  - **locking** — resolvido pelo lock nativo do S3 (`use_lockfile`); dois `apply`
    concorrentes agora colidem de forma controlada em vez de corromper o state;
  - **compartilhamento** — resolvido; múltiplos operadores/pipeline podem operar o mesmo
    state, respeitando o lock;
  - **dependência de uma única máquina** — resolvido; o state passa a residir no bucket,
    não no disco de quem roda o `apply`. Perder a máquina local não implica mais perder o
    mapeamento entre código e recursos reais.
  Um ponto **permanece como dívida, agora menor**:
  - **sem versionamento habilitado** no bucket `gitops-terraformcode33` — verificado via
    MCP AWS nesta revisão (`get-bucket-versioning` sem `Status` na resposta). Sem
    versionamento, não há como recuperar uma versão anterior de um state corrompido ou
    truncado por um `apply` interrompido; o dado ainda está protegido por locking (que
    remove a causa mais comum de corrupção — concorrência), mas não por backup de versão.
  - texto em claro no objeto de state: o objeto está protegido por SSE-S3 em repouso e por
    IAM/Public Access Block em acesso, mas continua sendo texto claro para quem tiver
    permissão de leitura — mesma característica de qualquer backend S3 sem criptografia do
    lado do cliente (fora de escopo aqui).
  Isso **substitui integralmente** a dívida de state descrita nas revisões 1–3; a prática
  A.3.1 passa a estar quase satisfeita (falta apenas o versionamento).
- **Sem IPv6**, sem VPC Endpoints, sem flow logs nesta primeira entrega (ver A.4).

### O que essa decisão trava (portas que fecham)

- **Alta disponibilidade de egress** — com um único NAT, a saída da AZ-b depende da AZ-a.
  Reversível com custo (Opção B), sem mudança de endereçamento.
- **ALB sob carga real** — o ALB é criável, mas as subnets `/28` não sustentam sua escala
  horizontal conforme a recomendação da AWS.
- **EKS fica inviável**: cada pod consome um IP de subnet com o VPC CNI em modo padrão;
  11 IPs por subnet privada esgotam com pouquíssimos pods, e as ENIs secundárias pré-alocam
  IPs, agravando o quadro. Se EKS entrar no roadmap, este ADR precisa ser substituído.
- **Terceira AZ, subnet dedicada de banco ou múltiplos Interface Endpoints** — não há espaço
  no `/26` para nada disso sem CIDR secundário.
- ~~Operação por pipeline de CI/CD fica travada enquanto o state for local~~ — **resolvido
  na revisão 4:** com backend remoto e lock nativo do S3, um runner efêmero passa a
  conseguir operar o state normalmente. A implementação do pipeline em si **continua fora
  de escopo** (ver A.4).
- ~~Trabalho em equipe sobre a mesma infraestrutura — uma pessoa por vez, uma máquina só~~
  — **atenuado na revisão 4:** o backend remoto com lock permite múltiplas
  máquinas/operadores tecnicamente. A restrição de "uma pessoa por vez" deixa de ser uma
  limitação técnica e passa a ser, no máximo, uma convenção de processo (ver A.5,
  pergunta 7).

### Condições de reversão

Este ADR deve ser revisto se qualquer uma destas ocorrer:

1. **O egress da AZ-b se tornar crítico**, ou a fatura de transferência cross-AZ ficar
   relevante → adotar a Opção B (um NAT por AZ), desdobrando a route table privada em duas
   e aceitando o consumo de mais um IP na subnet pública da AZ-b.
2. O consumo de IPs passar de ~60% em qualquer subnet (≈7 dos 11), **ou** o ALB precisar
   escalar além de um nó por AZ → novo ADR de endereçamento: CIDR secundário na VPC com
   subnets `/27`, ou VPC nova com `/25` ou maior.
3. ~~Segunda pessoa ou pipeline precisar aplicar mudanças, ou um incidente de state ocorrer
   → migrar imediatamente para backend remoto com locking~~ — **executada
   preventivamente na revisão 4**, a pedido do usuário, sem que o gatilho original (segunda
   pessoa/pipeline ou incidente) tenha ocorrido. **Nova condição de reversão 3:** se o
   bucket de state permanecer sem versionamento habilitado até a ocorrência de um
   incidente de corrupção de state, revisar formalmente se esse gap ainda é aceitável (ver
   Seção 6 e A.5, pergunta 4).
4. A fatura de NAT (hora + GB + cross-AZ) superar o custo de alternativas → avaliar VPC
   Endpoints para os destinos de maior volume (S3 e ECR são os candidatos típicos), com a
   ressalva de que cada Interface Endpoint consome um IP **por AZ**.
5. O NAT Gateway regional (`availability_mode = "regional"`) se confirmar disponível na
   região alvo com preço competitivo → reavaliar como caminho de HA de egress sem duplicar
   recursos nem consumir IP adicional.
6. EKS entrar no roadmap → este ADR deve ser **substituído**, não revisado.

## 6. Riscos e mitigações

| Risco | Probabilidade | Impacto | Mitigação |
|---|---|---|---|
| Falha da AZ-a → perda do egress das duas subnets privadas | Baixa | Médio a alto | Aceito conscientemente. Runbook: recriar o NAT na subnet pública da AZ-b e repontar a route table privada. O código não deve hardcodar a AZ do NAT, para que isso seja mudança de variável e não reescrita |
| **ALB entra em falha de escala por falta de IPs livres na subnet `/28`** | Média se houver carga real; baixa no perfil de workshop | Alto (5xx, timeouts) | Manter apenas ALB e NAT nas subnets públicas — nenhum outro recurso com ENI; alarme de IPs livres por subnet; condição de reversão 2 (CIDR secundário) |
| Esgotamento de IPs (11 por subnet) | **Alta** | Alto (irreversível sem CIDR secundário) | Alarme sobre IPs disponíveis por subnet; gate de revisão em 7 IPs usados; não usar estas subnets para EKS/VPC CNI nem para múltiplos Interface Endpoints |
| Custo de transferência cross-AZ do egress da AZ-b acima do previsto | Baixa no volume assumido | Baixo | Concentrar workloads de maior egress na AZ-a; monitorar por Cost Explorer; condição de reversão 1 |
| Corrupção ou perda do state (objeto no bucket remoto) | Baixa (revisão 4: caiu de Média) | Médio (revisão 4: caiu de Alto) | **Resolvido/atenuado na revisão 4:** o state passa a residir no bucket `gitops-terraformcode33`, fora de qualquer máquina individual — perda de máquina local não afeta mais o state. Risco residual: corrupção do objeto **sem** versionamento habilitado impede reverter para uma versão anterior. Recomendação: habilitar versionamento no bucket antes do primeiro `apply` real desta VPC |
| `apply` concorrente por duas execuções simultâneas | Baixa (revisão 4: um único operador segue sendo a prática) | Baixo (revisão 4: caiu de Alto) | **Resolvido na revisão 4:** lock nativo do S3 (`use_lockfile`) bloqueia `apply` concorrente automaticamente — a segunda execução aguarda ou falha com erro de lock, em vez de corromper o state silenciosamente |
| Custo por GB do NAT acima do esperado | Baixa | Baixo | Budget/alarme de custo com filtro por serviço; destruir a stack fora de uso (decisão já tomada pelo usuário) |
| EIP alocado e não associado (cobrança silenciosa) ou estouro da quota de 5 EIPs/região | Baixa | Baixo | EIP criado sempre junto ao NAT no mesmo módulo; quota padrão de Elastic IPs por região é 5 (verificado) — 1 uso aqui, folga adequada mesmo se a Opção B for adotada |
| Destruição acidental da VPC via `terraform destroy` levando workloads junto | Média | Alto | **Atenuado na revisão 4:** o lock nativo do S3 impede que duas execuções (`destroy` e `apply`, por exemplo) rodem simultaneamente sobre o mesmo state. Mitigações remanescentes, ainda necessárias: rede em diretório/estado separado dos workloads; revisão obrigatória do `terraform plan` antes de todo `apply` |
| Ciclo de destroy/recreate diário deixando recursos órfãos (EIP, ENI) e cobrança residual | Média | Baixo a médio | Após cada `destroy`, conferir que EIP e NAT foram efetivamente liberados; um EIP não associado continua sendo cobrado |
| NAT Gateway criado antes do Internet Gateway estar anexado → falha ou NAT sem saída | Média | Médio | Dependência explícita do NAT em relação ao Internet Gateway (a documentação do provider recomenda `depends_on` para garantir a ordem) |
| Subnets públicas expondo instâncias sem intenção | Baixa | Alto | `map_public_ip_on_launch` em `false`; nenhum workload de aplicação em subnet pública — apenas load balancer e o próprio NAT |
| Data source de AZs retornar AZs em ordem diferente entre execuções, remapeando subnets | Baixa | Médio | Ordenar deterministicamente a lista de AZs e fixar o mapeamento índice→subnet; qualquer mudança de AZ aparece no `plan` como recriação de subnet e deve barrar o `apply` |
| **[Novo — revisão 4] Bucket de state `gitops-terraformcode33` sem versionamento habilitado** | Média (até ser corrigido) | Médio (perda do histórico de state em caso de corrupção do objeto) | Habilitar versionamento no bucket antes do primeiro `apply` real desta VPC; até lá, tratar como dívida ativa (Seção 5); ação administrativa sobre o bucket, fora do escopo de criação deste módulo (ver A.4) |
| **[Novo — revisão 4] Máquina/runner com Terraform `< 1.10.0` tentando usar `use_lockfile`** | Baixa a média (depende do ambiente de cada operador) | Médio (`apply` falha, ou o backend se comporta sem lock efetivo em versão incompatível) | Fixar `required_version >= 1.10.0` no bloco `terraform` (A.3.2); documentar esse pré-requisito para qualquer runner/máquina que operar este backend |

## 7. Segurança, custo e operação

### IAM

- O provisionamento é feito por uma **role/identidade dedicada de infraestrutura**, com
  credenciais de curta duração. Humanos não usam credenciais permanentes de administrador.
- Permissões limitadas ao domínio EC2/VPC necessário (VPC, subnet, route table, IGW, EIP,
  NAT gateway, tags). Nada de `*:*`.
- **Atualizado na revisão 4:** a role/identidade de infraestrutura passa a precisar de
  permissão de leitura/escrita sobre o objeto de state no bucket `gitops-terraformcode33`
  — no mínimo `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` no prefixo/`key` usado por
  este ambiente, e `s3:ListBucket` no bucket (necessário para o lock nativo verificar o
  objeto de lock). Escopar por **prefixo**, não pelo bucket inteiro, é recomendado caso o
  bucket venha a ser compartilhado por outros projetos do workshop (ver A.5, pergunta 6).
  **Não é necessária** permissão de DynamoDB — o lock é nativo do S3, não usa tabela. O
  JSON exato da policy **não foi verificado** nesta sessão; o implementador deve desenhá-la
  com escopo mínimo antes do `apply`.
- Papéis distintos para `plan` (leitura) e `apply` (escrita) permanecem recomendados. Com
  backend remoto, esse desenho volta a fazer sentido pleno (deixou de ser "algo a retomar
  junto com o pipeline" só para a camada de state) — mas sua implementação continua fora
  de escopo deste ADR (ver A.4).

### Rede

- **Superfície pública:** apenas o Internet Gateway e o Elastic IP do NAT. Nenhum recurso de
  aplicação recebe IP público por padrão.
- **Segmentação:** subnets públicas destinadas exclusivamente a load balancer e ao NAT;
  todo workload de aplicação e dado vai para as subnets privadas. Essa regra deixa de ser
  apenas boa prática aqui: com `/28`, colocar qualquer outra coisa na subnet pública come a
  folga de IP que o ALB precisa.
- **Egress:** unidirecional a partir das privadas (NAT não aceita conexão iniciada de fora).
- **Network ACLs:** manter a NACL default (permissiva) e fazer o controle em Security
  Groups. NACL só entra se surgir requisito explícito — é stateless e uma fonte comum de
  incidente difícil de depurar.
- **Security Groups não fazem parte deste ADR** (ver A.4): pertencem à camada de workload.

### Observabilidade

- **VPC Flow Logs:** recomendado, mas fora do escopo desta entrega (ver A.4). Se ativado,
  destino CloudWatch Logs ou S3 com retenção curta (7–14 dias) para conter custo.
- **Métricas a acompanhar no NAT Gateway** (CloudWatch, namespace `AWS/NATGateway`):
  bytes processados, pacotes descartados, contagem de conexões ativas e falhas de
  alocação de porta.
- **Alertas mínimos sugeridos:**
  1. Pacotes descartados pelo NAT acima de zero de forma sustentada (sinal de saturação).
  2. Falha de alocação de porta > 0 (sinal de esgotamento de portas / necessidade de EIP
     secundário ou de um segundo NAT).
  3. Budget mensal de custo estourando o limiar definido.
  4. **IPs livres por subnet abaixo de 4** (com 11 utilizáveis, é o limiar em que o ALB
     perde a margem de 8 IPs livres). Este é o alarme mais importante desta arquitetura.
- **Nomes exatos das métricas do CloudWatch não foram verificados nesta sessão** — o
  implementador deve confirmá-los na documentação antes de criar os alarmes.

### Backup / DR

- A camada de rede **não tem estado de dados**. O "backup" é o próprio código Terraform
  versionado em Git.
- **Atualizado na revisão 4:** o state do Terraform passa a residir no bucket S3
  `gitops-terraformcode33`, fora da máquina do operador — elimina o risco de perda por
  falha de disco/máquina local. **Continua sem backup por versionamento**: verificado via
  MCP AWS nesta sessão que o bucket está com versionamento **desabilitado**; recomendação
  operacional é habilitá-lo antes do primeiro `apply` real desta VPC. Até lá, a cópia
  manual do state fora do bucket segue válida como mitigação adicional (paliativo), mas
  deixou de ser a única defesa contra perda.
- RTO de recriação da rede: minutos (aplicação de um plano em uma conta limpa) — **desde que
  o state esteja íntegro no bucket**. Sem versionamento, um state corrompido no bucket ainda
  exige `import` manual, exatamente como no cenário de state local.
- RPO: não aplicável à rede.
- Recuperação de falha da AZ-a: os recursos da AZ-b sobrevivem; o **egress** é restaurado
  recriando o NAT na subnet pública da AZ-b e repontando a route table privada.

### Estimativa de custo (ordem de grandeza)

| Item | Ordem de grandeza | Observação |
|---|---|---|
| NAT Gateway (custo fixo por hora) | Dezenas de USD/mês se ficar 24x7 | **Driver dominante.** Cobrado mesmo com tráfego zero. Continua sendo **um só** com 2 AZs |
| NAT Gateway (por GB processado) | Unidades de USD/mês no perfil assumido | Cresce linear com o egress |
| Transferência cross-AZ (AZ-b → NAT na AZ-a) | Unidades de USD/mês no perfil assumido | **Volta a existir na revisão 3.** Proporcional ao egress originado na AZ-b |
| Elastic IP associado ao NAT | Baixo | EIP não associado é cobrado à parte |
| ALB, se provisionado (fora deste ADR) | Dezenas de USD/mês se 24x7 | Só citado para contexto; não faz parte desta entrega |
| VPC, subnets, route tables, Internet Gateway | Sem custo direto | — |
| **[Revisão 4] Bucket S3 de backend (`gitops-terraformcode33`)** | Desprezível (poucos KB por objeto de state; sem custo de tabela DynamoDB, pois o lock é nativo do S3) | Bucket já existe e já era cobrado fora desta entrega; nenhum custo incremental relevante introduzido por esta decisão |

**Total esperado desta entrega: dezenas de USD/mês se o ambiente ficar ligado 24x7**, quase
inteiramente atribuível ao NAT Gateway. O backend de state (revisão 4) não muda essa ordem
de grandeza. _Preços unitários não foram verificados nesta sessão._

**Alavanca de economia confirmada pelo usuário:** o ambiente **será destruído fora do
horário de uso**. Como o custo é dominado por um item cobrado por hora, isso reduz a fatura
aproximadamente na proporção do tempo desligado — um ambiente usado 20h/semana custa cerca
de 12% do valor de um ambiente 24x7. Consequências operacionais desse ciclo:

- O `destroy` deve ser **completo** (NAT + EIP), senão o EIP órfão continua sendo cobrado.
- Cada `recreate` gera um **novo IP público de NAT**; qualquer allowlist externa baseada
  nesse IP quebra a cada ciclo. Se isso for necessário, o EIP precisa ser preservado fora do
  ciclo de destroy — decisão para outro momento.
- O ciclo depende do state estar íntegro. **Atualizado na revisão 4:** com backend remoto,
  um `destroy` a partir de uma máquina local perdida não é mais um problema — o state
  continua no bucket. O risco equivalente agora é um `destroy`/`apply` rodando sobre um
  state corrompido no bucket sem versionamento para reverter.
- **Automatizar o ciclo destroy/recreate (agendamento) é um próximo passo recomendado, não
  um requisito desta entrega.** Fica registrado como candidato a ADR futuro, junto com o
  pipeline.

---

# Anexo A — Plano de Implementação (para o agente DevOps Engineer)

> Este anexo só é executável se o Status deste ADR for
> "Aprovado para implementação". Enquanto for "Proposto", o agente DevOps
> Engineer deve ignorá-lo. **A Etapa 0 abaixo (backend remoto), introduzida na revisão 4,
> depende adicionalmente da confirmação humana específica descrita na nota do cabeçalho
> deste documento antes de ser executada.**

## A.1 Sequência de execução

> **Nota de revisão 2/3 (histórico):** a etapa "Backend remoto de state" foi removida do
> plano na revisão 2, por decisão explícita do usuário, e não era pré-requisito bloqueante
> — o `terraform init` rodava com backend local. Na revisão 3, as Etapas 2, 3 e 5 passaram a
> tratar de 4 subnets e 2 AZs.
> **Nota de revisão 4:** a etapa de backend remoto **volta ao plano de execução**, como
> **Etapa 0** abaixo, e passa a ser pré-requisito das demais etapas. O bucket já existe
> (`gitops-terraformcode33`) — esta etapa **não cria** o bucket, apenas configura o bloco
> `backend "s3"` e, se houver state local prévio de uma aplicação anterior deste mesmo ADR,
> conduz a migração via `terraform init -migrate-state`.

### Etapa 0 — Configuração do backend remoto (pré-requisito, nova na revisão 4)

- **Objetivo:** apontar esta composição Terraform para o bucket de state remoto já
  provisionado, com lock nativo do S3.
- **Componentes:** bloco `terraform { backend "s3" { bucket = "gitops-terraformcode33",
  key = <definir por ambiente, ver A.5 pergunta 5>, region = "us-east-1", use_lockfile =
  true } }`; bloco `terraform { required_version = ">= 1.10.0, < 2.0.0" }` (faixa exata a
  critério do implementador) — **obrigatório**, pois `use_lockfile` requer Terraform ≥
  1.10.0. Este Terraform **não cria** o bucket `aws_s3_bucket` correspondente — ele já
  existe fora deste módulo (ver A.4).
- **Ponto de atenção verificado via MCP AWS nesta sessão:** o bucket já existe em
  `us-east-1`, com SSE-S3 (AES256) habilitada e Public Access Block totalmente habilitado.
  **Versionamento está desabilitado** — recomenda-se habilitá-lo (ação administrativa sobre
  o bucket, fora do escopo de criação deste módulo) antes de considerar esta etapa
  "pronta para produção do workshop", ainda que não seja bloqueante para o `init`.
- **Critério de aceite:** `terraform init` conclui sem erro apontando para o backend
  remoto; se havia state local de uma aplicação anterior deste ADR, a migração é confirmada
  interativamente e o `terraform plan` subsequente não mostra diferenças; um segundo
  `apply` disparado enquanto o primeiro está em curso é bloqueado ou aguarda pelo lock
  (mensagem de erro/espera de lock do backend `s3`).
- **Reversão:** `terraform init -migrate-state` de volta a um bloco de backend local —
  **não recomendado**, pois reintroduz integralmente a dívida de state descrita nas
  revisões 1–3.
- **Dependência:** nenhuma nova infraestrutura de rede; é pré-requisito de todas as etapas
  seguintes.

### Etapa 1 — VPC

- **Objetivo:** criar a VPC `10.0.0.0/26` com resolução de DNS.
- **Componentes:** `aws_vpc` (CIDR `10.0.0.0/26`, DNS support e DNS hostnames habilitados).
- **Critério de aceite:** VPC existe com o CIDR exato `10.0.0.0/26`; atributos de DNS
  confirmados via `describe-vpc-attribute`; `terraform plan` subsequente sem diferenças;
  tags `Project=dvn` e `Environment=dev` presentes.
- **Reversão:** destroy da VPC (sem dependentes nesta etapa).
- **Dependência:** Etapa 0 (backend remoto configurado). _(Atualizado na revisão 4 — antes
  da revisão 4, esta etapa não tinha dependência, pois o state era local.)_

### Etapa 2 — Subnets (4, em 2 AZs)

- **Objetivo:** criar as 2 subnets públicas e as 2 subnets privadas, uma de cada em cada AZ,
  conforme a tabela da Seção 4.
- **Componentes:** `aws_subnet` x4 — pública-a `10.0.0.0/28`, pública-b `10.0.0.16/28`,
  privada-a `10.0.0.32/28`, privada-b `10.0.0.48/28`. As AZs são resolvidas via data source
  de AZs disponíveis (dois primeiros elementos, em ordem determinística), **nunca
  hardcoded**. `map_public_ip_on_launch` explicitamente `false` nas quatro.
- **Critério de aceite:** as 4 subnets existem com os CIDRs exatos; pública-a e privada-a na
  **mesma** AZ; pública-b e privada-b na **outra** AZ; as duas AZs são distintas; nenhuma
  sobreposição de CIDR; a soma dos quatro blocos cobre o `/26` sem sobra; nomes seguindo a
  convenção (`dvn-dev-public-subnet-a/b`, `dvn-dev-private-subnet-a/b`).
- **Reversão:** destroy das subnets.
- **Dependência:** Etapa 1.

### Etapa 3 — Internet Gateway e roteamento público

- **Objetivo:** dar entrada/saída de internet às subnets públicas.
- **Componentes:** `aws_internet_gateway` anexado à VPC; `aws_route_table` pública **única**
  com rota `0.0.0.0/0` → IGW; `aws_route_table_association` **x2** (as duas subnets
  públicas).
- **Critério de aceite:** route table pública contém a rota default para o IGW e está
  associada exatamente às duas subnets públicas; um host de teste em subnet pública com IP
  público alcança a internet.
- **Reversão:** remover associações, route table e IGW (nesta ordem).
- **Dependência:** Etapa 2.

### Etapa 4 — Elastic IP e NAT Gateway único

- **Objetivo:** prover egress às subnets privadas por um único NAT.
- **Componentes:** `aws_eip` (escopo de VPC) e `aws_nat_gateway` (`connectivity_type`
  público — padrão), colocado na **subnet pública da AZ-a**.
- **Ponto de atenção verificado na documentação do provider:** o NAT Gateway deve declarar
  **dependência explícita do Internet Gateway** para garantir a ordem correta de criação e
  destruição. Sem isso há risco de NAT criado sem caminho de saída ou de falha no destroy.
- **Critério de aceite:** NAT Gateway em estado `available`, com EIP associado, na subnet
  pública da AZ-a; a subnet pública da AZ-a mantém **ao menos 8 IPs livres** após a criação
  do NAT (verificação explícita, por causa do `/28`).
- **Reversão:** destruir NAT Gateway e depois liberar o EIP (EIP órfão continua sendo
  cobrado — verificar liberação, especialmente por causa do ciclo diário de destroy).
- **Dependência:** Etapa 3.

### Etapa 5 — Roteamento privado

- **Objetivo:** apontar o egress das duas subnets privadas para o NAT.
- **Componentes:** `aws_route_table` privada **única** com rota `0.0.0.0/0` → NAT Gateway;
  `aws_route_table_association` **x2** (as duas subnets privadas).
- **Critério de aceite:** as duas subnets privadas estão associadas à route table privada e
  **não** à route table default/main; um host de teste em cada subnet privada, sem IP
  público, alcança a internet e o IP de origem observado é o EIP do NAT — **inclusive a
  partir da AZ-b**, o que valida o caminho cross-AZ.
- **Reversão:** remover as associações (as subnets voltam à route table main da VPC — o que
  as deixa sem egress, comportamento seguro).
- **Dependência:** Etapa 4.

### Etapa 6 — Outputs e validação final

- **Objetivo:** expor identificadores para as stacks de workload consumirem.
- **Componentes:** outputs de `vpc_id`, CIDR da VPC, **listas** de IDs das subnets públicas
  e privadas, IDs das route tables, IP público do NAT e as **AZs utilizadas**.
- **Critério de aceite:** `terraform plan` limpo após o apply; outputs presentes e as listas
  de subnets contendo 2 elementos cada, em AZs distintas (formato consumível por
  `subnet_ids` de ALB e por DB subnet group); tags obrigatórias aplicadas em todos os
  recursos; validação de que as subnets privadas **não** possuem rota para o IGW;
  **atualizado na revisão 4:** confirmação de que o state reside no backend remoto
  (`gitops-terraformcode33`) e não há mais `*.tfstate` local versionável no diretório de
  trabalho.
- **Reversão:** remover outputs (sem efeito sobre a infraestrutura).
- **Dependência:** Etapa 5.

## A.2 Layout de diretórios

```
gitops-workshop-dvn/
├── docs/                          # ADRs e documentação de decisão (este diretório)
├── dvn-workshop-apps/             # Código das aplicações (já existente, não tocar)
└── infra/                         # Toda a infraestrutura como código
    └── terraform/
        ├── modules/
        │   └── network/           # Módulo reutilizável de rede (VPC, subnets, IGW, NAT, rotas)
        └── environments/
            └── dev/               # Composição do ambiente dev: provider e chamada do módulo
                                    # (revisão 4: bloco `backend "s3"` apontando para
                                    # gitops-terraformcode33, com use_lockfile = true)
```

**Convenções de nomenclatura (prefixo de projeto `dvn` confirmado pelo usuário):**

- Recursos AWS: `{projeto}-{ambiente}-{componente}-{az-suffix}`, com `projeto = dvn` e
  `ambiente = dev`. Exemplos concretos deste ADR:
  - `dvn-dev-vpc`
  - `dvn-dev-public-subnet-a` / `dvn-dev-public-subnet-b`
  - `dvn-dev-private-subnet-a` / `dvn-dev-private-subnet-b`
  - `dvn-dev-igw`
  - `dvn-dev-nat-a`
  - `dvn-dev-public-rt`
  - `dvn-dev-private-rt`
- Os sufixos `-a` e `-b` referem-se ao **índice da AZ resolvida pelo data source**, não aos
  literais `us-east-1a`/`us-east-1b`.
- O NAT carrega o sufixo `-a` deliberadamente: ele registra em qual AZ o único NAT vive, e
  torna óbvio o que muda se a Opção B for adotada.
- Arquivos Terraform dentro do módulo: separados por responsabilidade
  (`main`, `variables`, `outputs`, `versions`), não um arquivo monolítico.
- Nomes de recursos em `snake_case`; nomes de recursos AWS (tag `Name`) em `kebab-case`.
- Uma pasta por ambiente em `environments/`, cada uma com seu próprio state.
  **Atualizado na revisão 4:** "seu próprio state" agora significa sua própria `key` dentro
  do bucket remoto compartilhado, não seu próprio arquivo local (ver A.5, pergunta 5).
- **`.gitignore` deve excluir `*.tfstate`, `*.tfstate.backup` e `.terraform/`.** Mantido
  mesmo com backend remoto: qualquer `terraform init -migrate-state` ou execução acidental
  sem o bloco de backend pode gerar state local temporário, que não deve ser commitado.

## A.3 Boas práticas obrigatórias

1. **State remoto com locking, criptografia e versionamento.**
   _Motivo:_ state local não é compartilhável, não protege contra apply concorrente e
   contém dados sensíveis. Versionamento é a única forma prática de recuperar um state
   corrompido.
   **Atualizado na revisão 4:** locking (lock nativo do S3, `use_lockfile`) e criptografia
   (SSE-S3, verificada no bucket via MCP AWS) estão **satisfeitos**. **Versionamento
   continua pendente** — o bucket `gitops-terraformcode33` foi verificado sem
   versionamento habilitado nesta sessão; habilitá-lo é recomendado antes do primeiro
   `apply` real, mas não é criado por este módulo (o bucket já existe fora do escopo de
   criação deste Terraform). Compensação processual residual: `plan` revisado antes de todo
   `apply` (item 12) segue sendo a defesa primária contra mudança destrutiva enquanto o
   versionamento não for habilitado.
2. **Versão do Terraform e do provider AWS fixadas com restrição pessimista.**
   _Motivo:_ evita que um `init` em outra máquina traga um provider com breaking change.
   A versão mais recente do provider `hashicorp/aws` verificada nesta sessão é **6.56.0**;
   o implementador deve fixar em uma faixa compatível e registrar a escolha.
   **Atualizado na revisão 4:** o backend `s3` com lock nativo (`use_lockfile`) exige
   **Terraform ≥ 1.10.0** — verificado via MCP AWS (AWS Prescriptive Guidance for
   Terraform). O bloco `terraform { required_version = ">= 1.10.0, < 2.0.0" }` (faixa
   exata a critério do implementador) passa a ser **obrigatório**, não apenas recomendado,
   em toda máquina/runner que operar este backend.
3. **Nenhuma AZ hardcoded.** Resolver as AZs via data source, em ordem determinística, e
   expor os índices como variável.
   _Motivo:_ nomes de AZ não são estáveis entre contas e o código deixa de ser portátil
   entre regiões. Uma reordenação silenciosa da lista remapearia subnets e forçaria
   recriação — o `plan` deve ser lido com atenção a isso.
4. **CIDRs das subnets derivados do CIDR da VPC**, não escritos literalmente.
   _Motivo:_ mantém a coerência do plano de endereçamento e reduz erro de digitação em
   máscara — a classe de bug mais cara aqui, porque subnet não se redimensiona. Com um `/26`
   dividido em quatro `/28` sem folga, um erro de máscara faz um dos blocos não caber.
5. **Tagging obrigatório via `default_tags` no provider**, no mínimo: `Project=dvn`,
   `Environment=dev`, `ManagedBy=terraform`, `Owner`, `CostCenter`.
   _Motivo:_ sem tags não há atribuição de custo nem distinção entre recurso gerenciado e
   recurso criado à mão.
6. **Separação de estados entre rede e workload.**
   _Motivo:_ a rede é longeva e a aplicação é volátil; um destroy de aplicação nunca deve
   ter poder de derrubar a VPC. **Atualizado na revisão 4:** com backend remoto, isso
   significa **`key`s distintas** dentro do mesmo bucket (ou bucket dedicado, ver A.5
   pergunta 6) para rede e para workload — não mais diretórios com arquivos de state local
   separados.
7. **`map_public_ip_on_launch = false` explícito em todas as subnets.**
   _Motivo:_ ser pública é propriedade da rota; atribuição automática de IP público é uma
   porta aberta por descuido.
8. **Nada além de load balancer e NAT nas subnets públicas.**
   _Motivo:_ com `/28`, cada ENI extra na subnet pública consome parte dos 8 IPs livres que
   o ALB precisa para escalar. Esta regra é a mitigação primária do risco de escala.
9. **Route table privada isolada em um recurso próprio e bem identificado.**
   _Motivo:_ é o exato ponto de mudança quando a Opção B (NAT por AZ) for adotada. Deve ser
   trivial encontrar e desdobrar em duas.
10. **Outputs de subnets expostos como listas (públicas e privadas separadas).**
    _Motivo:_ ALB e DB subnet group consomem conjuntos de subnets em AZs distintas; expor
    IDs individuais forçaria o consumidor a remontar a lista e convida a erro de AZ.
11. **Nenhum recurso criado fora do Terraform (sem ClickOps).**
    _Motivo:_ drift silencioso é o modo de falha mais comum em ambientes de workshop.
    **Nota da revisão 4:** o próprio bucket de backend (`gitops-terraformcode33`) já é uma
    exceção consciente a esta regra — foi criado fora deste Terraform, por decisão do
    usuário. Isso deve ficar explícito em qualquer documentação de onboarding, para não ser
    confundido com drift.
12. **`terraform plan` revisado antes de qualquer `apply`, e revisado em Pull Request
    sempre que houver mais de uma pessoa envolvida.**
    _Motivo:_ com locking (revisão 4), a revisão do plano deixa de ser a única barreira
    contra mudança destrutiva, mas continua sendo a barreira contra mudança **errada**
    (o lock protege contra concorrência, não contra um `plan` mal revisado).
13. **Nunca fazer `terraform destroy` de recursos com dependentes ativos sem checar
    reverse dependencies.**
    _Motivo:_ ENIs órfãs de load balancer ou de Lambda bloqueiam o destroy de subnet e
    deixam o state inconsistente. Relevante em dobro aqui, porque o ciclo de
    destroy/recreate será rotineiro.
14. **Após cada `destroy`, verificar na conta que NAT Gateway e Elastic IP foram
    efetivamente liberados.**
    _Motivo:_ o ciclo de destroy/recreate é a principal alavanca de custo desta arquitetura,
    e um EIP órfão anula parte da economia silenciosamente.

## A.4 Fora de escopo

Este ADR **não** cobre e **não** autoriza:

- ~~Backend remoto de state (S3 + locking) e seu bootstrap~~ — **removido desta lista na
  revisão 4**: adotado como Etapa 0 do Anexo A.1, usando o bucket já provisionado
  `gitops-terraformcode33` e lock nativo do S3. **Permanece fora de escopo,
  especificamente:**
  - a **criação** do bucket em si (já existe, provisionado fora deste
    Terraform/módulo — se precisar ser recriado ou movido, é objeto de outro ADR ou de um
    pequeno bootstrap separado, com seu próprio state);
  - a **habilitação de versionamento** no bucket (recomendada nesta revisão, não
    executada — ação administrativa sobre o bucket);
  - a definição de papéis IAM distintos para `plan`/`apply` sobre o backend (mencionada na
    Seção 7, não implementada aqui).
- **Automação do ciclo de destroy/recreate** (agendamento, gatilho, ferramenta) — o usuário
  confirmou que o ambiente será destruído fora de uso, mas a automação disso é um próximo
  passo, não parte desta entrega.
- **Criação do ALB e do RDS em si.** Esta entrega apenas garante que a topologia de rede os
  **permite** (2 subnets públicas em AZs distintas para o ALB; 2 subnets privadas em AZs
  distintas para o DB subnet group). Os recursos, seus Security Groups, certificados e
  parâmetros são de outro ADR.
- Security Groups e Network ACLs customizadas (camada de workload).
- VPC Flow Logs (recomendado, mas exige decisão sobre destino, retenção e custo).
- VPC Endpoints (Gateway ou Interface) — candidatos a um ADR de otimização de custo, com a
  ressalva de que cada Interface Endpoint consome um IP **por AZ** de subnets já apertadas.
- IPv6 e subnets dual-stack.
- Route 53 (zonas privadas) e certificados ACM.
- Conectividade híbrida: VPN, Direct Connect, Transit Gateway, VPC peering.
- Ambientes além do primeiro (`dev`): staging e produção exigem revisão do plano de
  endereçamento antes de serem replicados — o `/26` com subnets `/28` **não** deve ser
  replicado para produção.
- Escolha da plataforma de compute (ECS, EKS, EC2) — decisão de outro ADR, com impacto
  direto no consumo de IPs desta VPC. EKS, em particular, é incompatível com este
  endereçamento.
- Pipeline de CI/CD e a ferramenta de GitOps a ser adotada. **Atualizado na revisão 4:**
  esses itens não estão mais **tecnicamente bloqueados** pelo state (o backend remoto
  suporta execução por pipeline), mas continuam fora do escopo de **decisão** deste ADR.

## A.5 Perguntas abertas

> **Resolvidas e removidas desta lista:** tamanho do CIDR da VPC (`/26`); destruição fora de
> uso (sim); nome de projeto e ambiente (`dvn` / `dev`); qual AZ hospeda o NAT (AZ-a,
> decidido na Seção 4).
> **Resolvida na revisão 3:** a pergunta bloqueante da revisão 2 — "o roteiro prevê ALB ou
> RDS, que exigem 2 AZs?" — foi respondida pelo usuário com a decisão de **voltar a 2 AZs**.
> Ela deixa de ser bloqueante e sai desta lista.
> **Reaberta e re-resolvida na revisão 4:** a pergunta "backend de state" havia sido
> fechada nas revisões 2/3 como "não haverá nesta entrega". O usuário reabriu essa decisão
> na revisão 4 e ela foi respondida como "**haverá**, remoto, com o bucket
> `gitops-terraformcode33` já provisionado e lock nativo do S3". Novas perguntas derivadas
> dessa mudança entram na lista abaixo (itens 4–7).

1. **Qual é a região alvo?** Este ADR assumiu `us-east-1`. Confirmação necessária antes do
   apply. É a única pergunta remanescente da revisão 1 e **permanece aberta** — reforçada
   indiretamente pela revisão 4, já que o bucket de backend verificado está em `us-east-1`.
2. **O ALB será exposto a tráfego real (aula com muitos participantes simultâneos) ou apenas
   a tráfego de demonstração?** Não é bloqueante para o apply, mas define se a dívida de
   subnets `/28` é aceitável ou se a condição de reversão 2 (CIDR secundário com subnets
   `/27`) deve ser antecipada para antes da aula.
3. **Confirma-se manter o `/26` mesmo ciente da recomendação da AWS de `/27` para subnets de
   ALB?** O arquiteto recomenda formalmente `/25` (ou `/26` + CIDR secundário). A decisão de
   permanecer em `/26` é do usuário e está registrada como dívida na Seção 3 — esta pergunta
   existe para que a aceitação seja explícita no momento da aprovação.
4. **[Nova — revisão 4] O versionamento do bucket `gitops-terraformcode33` será habilitado
   antes do primeiro `apply` real desta VPC?** Não bloqueia o `terraform init`, mas é a
   única lacuna restante da dívida de state (Seção 5, Seção 6). Recomendação do arquiteto:
   sim, habilitar antes. **Não bloqueante, mas fortemente recomendada.**
5. **[Nova — revisão 4, bloqueante para a Etapa 0] Qual `key` (caminho do objeto de state)
   será usada para o ambiente `dev` desta rede dentro do bucket compartilhado?** Define se o
   bucket será compartilhado entre múltiplos projetos/ambientes do workshop e como evitar
   colisão de `key` entre eles. Sem essa definição, a Etapa 0 do Anexo A.1 não pode ser
   executada de forma segura.
6. **[Nova — revisão 4] O bucket `gitops-terraformcode33` é dedicado a este projeto ou
   compartilhado com outros?** Se compartilhado, a policy IAM da Seção 7 deve ser escopada
   por prefixo, não pelo bucket inteiro — muda o desenho de permissões e é pré-requisito
   para a policy do implementador.
7. **[Nova — revisão 4] A premissa de "operador único, sem apply concorrente" (Seção 2,
   item 11) continua valendo agora que o backend suporta múltiplos operadores/pipeline?**
   Não é bloqueante tecnicamente — o lock nativo do S3 protege de qualquer forma — mas
   define se o item A.3.12 (revisão de `plan` em Pull Request) deve ser antecipado antes de
   uma segunda pessoa começar a operar esta infraestrutura.

---

# Fontes consultadas

- **MCP Terraform — verificado (revisão 1):**
  - Versão mais recente do provider `hashicorp/aws`: **6.56.0**.
  - Recurso `aws_nat_gateway`: existência e argumentos `allocation_id`, `subnet_id`,
    `connectivity_type` (`public`/`private`, default `public`), `availability_mode`
    (`zonal`/`regional`, default `zonal`), `secondary_allocation_ids`, `tags`; atributos
    `public_ip`, `network_interface_id`, `association_id`; recomendação de dependência
    explícita em relação ao Internet Gateway.
  - Recurso `aws_subnet`: existência e argumentos `vpc_id` (obrigatório), `cidr_block`,
    `availability_zone`, `availability_zone_id`, `map_public_ip_on_launch` (default
    `false`), `tags`.
  - Recurso `aws_eip`: existência confirmada na listagem do provider; uso com escopo de VPC
    (`domain = "vpc"`) observado no exemplo oficial de `aws_nat_gateway`.
  - Recursos `aws_route_table`, `aws_route_table_association` e
    `aws_main_route_table_association`: existência confirmada na listagem do provider.

- **MCP AWS — verificado (revisão 1):**
  - Disponibilidade das APIs `EC2+CreateVpc` e `EC2+CreateNatGateway`: `isAvailableIn` em
    `us-east-1` e em `sa-east-1`.
  - Quota "Elastic IP addresses per Region": padrão **5**, ajustável.
  - Quota "Elastic IP addresses per public NAT gateway": padrão **2**, ajustável até 8.

- **MCP AWS — verificado (revisão 2):**
  - **Sizing de subnet IPv4:** bitmask permitido entre `/28` e `/16`; os **quatro primeiros
    endereços e o último** de cada bloco são reservados pela AWS (5 no total) — base do
    cálculo de 11 IPs utilizáveis em um `/28`. Fonte: Amazon VPC User Guide, "Subnet CIDR
    blocks / Subnet sizing for IPv4".
  - **RDS DB subnet group:** deve conter subnets em **pelo menos duas AZs**; a API rejeita o
    contrário com `DBSubnetGroupDoesNotCoverEnoughAZs`.
  - **Well-Architected REL02-BP03:** confirma como anti-padrão criar VPCs e subnets
    pequenas e recomenda deixar espaço livre de CIDR para expansão — base da ressalva 1.1.

- **MCP AWS — verificado (revisão 3), com uma correção do que foi registrado na revisão 2:**
  - **Application Load Balancer — requisito de AZ (confirmado):** "You must select at least
    two Availability Zone subnets… Each subnet must be from a different Availability Zone."
    Fonte: Elastic Load Balancing User Guide, "Application Load Balancers — Availability
    Zone subnets". Também confirmado na referência de `subnetMappings` da API ELBv2:
    "[Application Load Balancers] You must specify subnets from at least two Availability
    Zones."
  - **⚠ CORREÇÃO da revisão 2 quanto ao bitmask `/27`:** a revisão 2 afirmava que `/27` era o
    "bitmask mínimo exigido" para subnets de ALB. A redação real da documentação é uma
    **recomendação de dimensionamento**: "To ensure that your load balancer can scale
    properly, verify that each Availability Zone subnet … has a CIDR block with at least a
    `/27` bitmask … and at least eight free IP addresses per subnet." O documento descreve a
    consequência de **ficar sem IPs livres** (capacidade insuficiente, 5xx, timeouts), não
    uma rejeição de criação por bitmask. Confirmado de forma consistente pelo artigo "Scaling
    strategies for Elastic Load Balancing" ("we recommend that you use a minimum subnet size
    of /27") e pelos artigos de re:Post sobre subnets com IPs insuficientes, que tratam o
    limiar operacional como "menos de oito IPs disponíveis". Por isso a revisão 3 adota `/28`
    conscientemente, classificando-o como **abaixo da recomendação**, e não como
    **inviável**.
  - **Quota "IPv4 CIDR blocks per VPC":** padrão **5** (primário + secundários), ajustável
    até 50. Fonte: Amazon VPC quotas. Sustenta a saída futura de CIDR secundário citada na
    Seção 3 e na condição de reversão 2.
  - **Regras de CIDR secundário:** bloco permitido entre `/28` e `/16`, sem sobreposição com
    CIDR existente da VPC; tamanho de CIDR existente não pode ser aumentado nem diminuído.
    Fonte: Amazon VPC User Guide, "VPC CIDR blocks".
  - **Subnet pertence a uma única AZ:** confirmado implicitamente pela própria modelagem da
    documentação de subnets e pela exigência do ALB de "one subnet per Availability Zone" —
    base para descartar a hipótese de "subnet abrangendo múltiplas AZs" na Seção 3.

- **MCP AWS — verificado (revisão 4):**
  - **Mecanismo de state locking para backend S3 do Terraform:** AWS Prescriptive Guidance
    for Terraform AWS Provider confirma dois mecanismos: **lock nativo do S3 (recomendado)**
    — disponível desde o Terraform 1.10.0, configurado via `use_lockfile = true` no bloco
    `backend "s3"` — e **lock via DynamoDB (legado, em depreciação)**, mantido apenas por
    compatibilidade retroativa durante migração. Fonte: "Backend best practices",
    docs.aws.amazon.com/prescriptive-guidance/.../terraform-aws-provider-best-practices/backend.html.
    Isso resolve, a favor do lock nativo, o item que permanecia "não verificado" nas
    revisões 1–3.
  - **Bucket `gitops-terraformcode33` (via `aws s3api`):** existe na conta; região
    `us-east-1` (resposta de `get-bucket-location` vazia, que corresponde a `us-east-1`);
    criptografia padrão do lado do servidor **SSE-S3 (`AES256`)** habilitada, com
    `BucketKeyEnabled = true`; **Public Access Block totalmente habilitado**
    (`BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets`
    todos `true`); **versionamento NÃO habilitado** (resposta de `get-bucket-versioning`
    sem campo `Status`).
  - **Nenhuma tabela DynamoDB existente na conta** (`aws dynamodb list-tables` retornou
    lista vazia) — reforça a escolha do lock nativo do S3 em vez de criar uma tabela nova
    só para lock.

- **MCP Terraform — verificado (revisão 4):**
  - Listagem de sub-recursos do serviço `s3_bucket` no provider `hashicorp/aws` 6.56.0
    confirmando a existência de `aws_s3_bucket_versioning`, `aws_s3_bucket_public_access_block`
    e `aws_s3_bucket_server_side_encryption_configuration` como recursos disponíveis, caso um
    bootstrap separado do bucket venha a ser formalizado em Terraform no futuro (fora de
    escopo desta revisão, que trata o bucket como já existente e gerenciado fora deste
    módulo).

- **Não verificado (conhecimento prévio, requer confirmação antes do apply):**
  - Preços unitários de NAT Gateway (hora e por GB), de transferência cross-AZ e de
    Elastic IP.
  - Nomes exatos das métricas do CloudWatch no namespace `AWS/NATGateway` usadas nos
    alertas propostos, e a métrica/mecanismo para alarmar "IPs livres por subnet".
  - Argumentos do recurso `aws_vpc` (`enable_dns_support`, `enable_dns_hostnames`) — não
    foram consultados na documentação nesta sessão.
  - Argumentos do recurso `aws_route_table` (bloco `route`, `gateway_id`, `nat_gateway_id`)
    — apenas a existência do recurso foi confirmada.
  - Disponibilidade regional, preço e maturidade do NAT Gateway com
    `availability_mode = "regional"`.
  - Quota de subnets por VPC: a documentação de quotas indica **200 por VPC** (observado na
    mesma tabela de quotas), folgadíssima para este desenho; quota de route tables por VPC
    **não verificada**.
  - Comportamento exato do ALB quando criado em subnet `/28` com exatamente 8–10 IPs livres
    (a documentação descreve o risco, mas não há teste empírico nesta sessão).
  - **[Revisão 4]** JSON exato da policy IAM mínima para leitura/escrita do objeto de state
    e uso do lock nativo do S3 (ex.: se `s3:GetObjectVersion` é necessário sem
    versionamento habilitado, ou se o lock nativo exige alguma permissão adicional além de
    `PutObject`/`GetObject`/`DeleteObject`/`ListBucket`).
  - **[Revisão 4]** Se o bucket `gitops-terraformcode33` é dedicado a este projeto ou
    compartilhado com outros workloads/projetos da mesma conta — não verificado nesta
    sessão (ver A.5, pergunta 6).
  - **[Revisão 4]** Mensagem de erro exata que o Terraform ≥ 1.10.0 emite ao colidir com um
    lock nativo do S3 já existente (comportamento esperado, texto exato não verificado).

