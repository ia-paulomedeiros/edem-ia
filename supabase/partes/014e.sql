-- =============================================================================
-- 014e — parte 5 de 5 de supabase/014_paridade_regras.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 014d. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
grant select on public.v_clientes, public.v_fluxo_cards, public.v_juridico_cards, public.v_fila_leads, public.v_marketing_dia to authenticated;
grant execute on function public.brl(numeric) to authenticated;
grant execute on function public.tipo_saida(text) to authenticated;
grant execute on function public.vinculo_minimo_exigido(uuid, text, boolean, boolean) to authenticated;
grant execute on function public.office_escritorio(uuid) to authenticated;
grant execute on function public.ui_save_empresa(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.close_reasons() to authenticated;
grant execute on function public.ui_close_lead(uuid, text, text, text) to authenticated;
grant execute on function public.ui_reopen_lead(uuid, public.case_phase) to authenticated;
grant execute on function public.etapas() to authenticated;
grant execute on function public.etapa_titulo(text) to authenticated;
grant execute on function public.lead_etapa(uuid) to authenticated;
grant execute on function public.agent_label(text, text) to authenticated;
grant execute on function public.agent_for_lead(uuid) to authenticated;
grant execute on function public.agent_config_role(uuid, text) to authenticated;
grant execute on function public.agent_config_lead(uuid) to authenticated;
grant execute on function public.agent_label_lead(uuid) to authenticated;
grant execute on function public.ui_set_agent_persona(uuid, text, text) to authenticated;
grant execute on function public.journey_stages() to authenticated;
grant execute on function public.journey_stage_agents(text) to authenticated;
grant execute on function public.journey_stage_key(text) to authenticated;
grant execute on function public.lead_journey_stage(uuid) to authenticated;
grant execute on function public.lead_reached_stage(uuid, text) to authenticated;
grant execute on function public.lead_done_stage(uuid, text) to authenticated;
grant execute on function public.marketing_tokens_split(uuid, date, date) to authenticated;
grant execute on function public.marketing_dia_p(uuid, date, date) to authenticated;
grant execute on function public.marketing_lancar(uuid, date, numeric, numeric, text, numeric, numeric) to authenticated;
grant execute on function public.ui_move_to_column(uuid, text, text) to authenticated;
grant execute on function public.claim_intervention(uuid) to authenticated;
grant execute on function public.lead_dossier(uuid) to authenticated;

-- Só o banco/n8n.
revoke execute on function public.close_lead_with_reason(uuid, text, text, text, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.agent_prompt_render(public.agents, uuid) from public, anon, authenticated;
revoke execute on function public.agent_config_full(uuid, public.case_phase) from public, anon, authenticated;
revoke execute on function public.agent_config_full_lead(uuid) from public, anon, authenticated;
revoke execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.followup_no_template(uuid) from public, anon, authenticated;
revoke execute on function public.qualification_gate(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function public.advance_phase(uuid, public.case_phase, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.close_lead_with_reason(uuid, text, text, text, text, uuid, text) to service_role;
grant execute on function public.agent_prompt_render(public.agents, uuid) to service_role;
grant execute on function public.agent_config_full(uuid, public.case_phase) to service_role;
grant execute on function public.agent_config_full_lead(uuid) to service_role;
grant execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb) to service_role;
grant execute on function public.followup_no_template(uuid) to service_role;
grant execute on function public.qualification_gate(uuid, text, uuid) to service_role;
grant execute on function public.advance_phase(uuid, public.case_phase, text, uuid, text, text, text) to service_role;

-- ---------- Verificação da parte 014e: deve voltar uma linha com resultado = OK
select '014e' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('nada a conferir', true)
) as v(item, ok);
