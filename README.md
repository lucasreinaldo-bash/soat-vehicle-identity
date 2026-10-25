# Serviço de Identidade — Plataforma de Revenda de Veículos

Serviço responsável pelo **registro e pela autorização dos compradores** da plataforma de revenda
de veículos (Tech Challenge Fase 3 — SOAT PósTech).

Ele é **totalmente apartado** da API de vendas: processo, banco de dados e pipeline de deploy
próprios. Os dados pessoais dos clientes (nome, e-mail, CPF) vivem apenas aqui; a API de vendas
recebe somente um identificador opaco do cliente, via token JWT.

> Em construção. A documentação completa é adicionada à medida que o serviço é implementado,
> sempre via Pull Request.
