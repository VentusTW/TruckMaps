import 'package:flutter/material.dart';

import 'l10n.dart';

/// Jak pokazać wartość kolumny.
enum Format { text, code, date, flag, list, changes }

class Col {
  const Col(this.key, this.label, [this.format = Format.text]);

  final String key;
  final String Function(AdminLocalizations l) label;
  final Format format;
}

/// Filtr listy: parametr zapytania i dozwolone wartości (`null` – wszystkie).
class Filter {
  const Filter(this.param, this.label, this.values, {this.flag = false});

  final String param;
  final String Function(AdminLocalizations l) label;
  final List<String> values;

  /// Tak / nie (`true` / `false`) zamiast kodów z serwera.
  final bool flag;
}

/// Lista danych w programie administracyjnym: adres `/api/admin/<path>`, kolumny i filtry.
class Section {
  const Section(
    this.id,
    this.title,
    this.icon,
    this.columns, {
    this.search = 'q',
    this.filters = const [],
  });

  final String id;
  final String Function(AdminLocalizations l) title;
  final IconData icon;
  final List<Col> columns;

  /// Parametr wyszukiwania (`null` – bez pola wyszukiwania).
  final String? search;
  final List<Filter> filters;

  String get path => '/api/admin/$id';
}

const _roles = ['owner', 'dispatcher', 'driver'];
const _reportKinds = [
  'height_limit',
  'weight_limit',
  'no_trucks',
  'road_closed',
  'narrow',
  'other',
  'gate',
  'ramp',
  'office',
  'waiting_area',
  'hours',
];

final sections = <Section>[
  Section('accounts', (l) => l.sectionAccounts, Icons.person_outline, [
    Col('display_name', (l) => l.colDisplayName),
    Col('subject', (l) => l.colSubject),
    Col('language', (l) => l.colLanguage),
    Col('currency', (l) => l.colCurrency),
    Col('companies', (l) => l.colCompanies),
    Col('onboarded', (l) => l.colOnboarded, Format.flag),
  ]),
  Section('companies', (l) => l.sectionCompanies, Icons.business_outlined, [
    Col('name', (l) => l.colName),
    Col('tax_id', (l) => l.colTaxId),
    Col('members', (l) => l.colMembers),
    Col('cost_currency', (l) => l.colCurrency),
    Col('access_granted', (l) => l.colAccess, Format.flag),
    Col('created_at', (l) => l.colCreated, Format.date),
  ]),
  Section('members', (l) => l.sectionMembers, Icons.group_outlined, [
    Col('company_name', (l) => l.colCompany),
    Col('display_name', (l) => l.colDisplayName),
    Col('role', (l) => l.colRole, Format.code),
    Col('subject', (l) => l.colSubject),
    Col('joined_at', (l) => l.colJoined, Format.date),
  ], filters: [
    Filter('role', (l) => l.filterRole, _roles),
  ]),
  Section(
      'invites',
      (l) => l.sectionInvites,
      Icons.vpn_key_outlined,
      [
        Col('company_name', (l) => l.colCompany),
        Col('code', (l) => l.colCode),
        Col('role', (l) => l.colRole, Format.code),
        Col('note', (l) => l.colNote),
        Col('created_by', (l) => l.colCreatedBy),
        Col('expires_at', (l) => l.colExpires, Format.date),
      ],
      search: null,
      filters: [
        Filter('active', (l) => l.filterActive, ['true', 'false'], flag: true),
      ]),
  Section('bases', (l) => l.sectionBases, Icons.warehouse_outlined, [
    Col('company_name', (l) => l.colCompany),
    Col('name', (l) => l.colName),
    Col('label', (l) => l.colAddress),
  ]),
  Section('vehicles', (l) => l.sectionVehicles, Icons.local_shipping_outlined, [
    Col('name', (l) => l.colName),
    Col('plate', (l) => l.colPlate),
    Col('company_name', (l) => l.colCompany),
    Col('owner_subject', (l) => l.colOwner),
    Col('height_m', (l) => l.colHeight),
    Col('gvw_t', (l) => l.colGvw),
    Col('hazmat', (l) => l.colHazmat, Format.flag),
  ]),
  Section('reports', (l) => l.sectionReports, Icons.report_outlined, [
    Col('kind', (l) => l.colKind, Format.code),
    Col('note', (l) => l.colNote),
    Col('score', (l) => l.colScore),
    Col('subject', (l) => l.colSubject),
    Col('created_at', (l) => l.colCreated, Format.date),
  ], filters: [
    Filter('kind', (l) => l.filterKind, _reportKinds),
  ]),
  Section(
      'releases',
      (l) => l.sectionReleases,
      Icons.system_update_outlined,
      [
        Col('kind', (l) => l.colKind, Format.code),
        Col('name', (l) => l.colName),
        Col('platform', (l) => l.colPlatform),
        Col('version', (l) => l.colVersion),
        Col('status', (l) => l.colStatus, Format.code),
        Col('rollout', (l) => l.colRollout),
        Col('published_at', (l) => l.colCreated, Format.date),
      ],
      search: null,
      filters: [
        Filter('kind', (l) => l.filterKind, ['app', 'module', 'data']),
        Filter('status', (l) => l.filterStatus, ['active', 'paused', 'withdrawn']),
      ]),
  Section('licenses', (l) => l.sectionLicenses, Icons.workspace_premium_outlined, [
    Col('subject', (l) => l.colSubject),
    Col('modules', (l) => l.colModules, Format.list),
  ]),
  Section(
      'audit',
      (l) => l.sectionAudit,
      Icons.history,
      [
        Col('at', (l) => l.colTime, Format.date),
        Col('subject', (l) => l.colAdmin),
        Col('method', (l) => l.colMethod),
        Col('path', (l) => l.colPath),
        Col('status_code', (l) => l.colResult),
        Col('ip', (l) => l.colIp),
        Col('user_agent', (l) => l.colDevice),
        Col('action', (l) => l.colAction),
        Col('changes', (l) => l.colChanges, Format.changes),
      ],
      search: 'subject',
      filters: [
        Filter('changes_only', (l) => l.filterChangesOnly, ['true'], flag: true),
      ]),
];
