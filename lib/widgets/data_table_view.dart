// Reusable, dependency-free data table for list-style screens that need to
// be scanned rather than scrolled card-by-card (first used by the Service
// module: Service Overview, Alerts, Approvals, Items, Vehicle Service
// History, Garage Notifications).
//
// Features: sortable column headers (tap to sort, tap again to flip
// direction), a sticky header row, zebra rows, horizontal scroll when the
// viewport is narrower than the columns need, an optional pinned first
// column (stays put while the rest scrolls sideways — used for the truck
// number), a row-tap callback, an empty state, and simple client-side
// pagination (default 25 rows/page) so a few hundred rows never build at
// once.
//
// Layout: every row has a FIXED height (rowHeight) so the pinned column
// and the scrolling part always line up without measuring. The header's
// horizontal offset follows the body's (one-way listener; the header
// itself can't be dragged) so the header stays aligned while staying
// outside the vertical scroll — i.e. sticky.
import 'package:flutter/material.dart';

import '../app_theme.dart';

class DataTableColumn<T> {
  final String label;
  // Base width in logical px. When the viewport is wider than the sum of
  // every column's width, non-pinned columns are stretched proportionally
  // to fill it (desktop/web); when narrower, the table scrolls sideways.
  final double width;
  final Widget Function(BuildContext context, T row) cellBuilder;
  // Null = not sortable. Should be a total order; ties keep the incoming
  // order (the sort is stable).
  final int Function(T a, T b)? compare;
  final bool numeric;
  // Plain-text value of this cell for PDF/PNG export. Null = the column is
  // left out of exports (e.g. an Actions column of buttons).
  final String Function(T row)? exportValue;
  // Marks THE date column (values formatted YYYY-MM-DD) — exports use it to
  // state the date range the exported rows cover.
  final bool isDate;

  const DataTableColumn({
    required this.label,
    required this.width,
    required this.cellBuilder,
    this.compare,
    this.numeric = false,
    this.exportValue,
    this.isDate = false,
  });
}

// Lets code outside the table (the toolbar's Export button) read the rows
// exactly as the table currently orders them — every filtered row, all
// pages, in the active sort — plus which sort is active.
class DataTableController<T> {
  _DataTableViewState<T>? _state;

  bool get isAttached => _state != null;

  List<DataTableColumn<T>> get columns => _state?.widget.columns ?? const [];

  // All rows (not just the visible page), sorted as on screen.
  List<T> get sortedRows => _state?._sorted ?? const [];

  // e.g. "Status (ascending)"; null while no sort is active.
  String? get sortDescription {
    final st = _state;
    final col = st?._sortColumn;
    if (st == null || col == null || col >= st.widget.columns.length) return null;
    return '${st.widget.columns[col].label} (${st._ascending ? 'ascending' : 'descending'})';
  }
}

class DataTableView<T> extends StatefulWidget {
  final List<DataTableColumn<T>> columns;
  final List<T> rows;
  // Column whose comparator is the default sort. Null = keep rows in the
  // order given until a header is tapped.
  final int? initialSortColumn;
  final bool initialSortAscending;
  final void Function(T row)? onRowTap;
  final Widget? emptyState;
  final int pageSize;
  // 0 or 1. With 1, column 0 stays fixed while the rest scroll sideways.
  final int pinnedColumns;
  final double rowHeight;
  final double headerHeight;
  // Whenever this value changes (e.g. the caller's search text + filter
  // chip), pagination jumps back to page 1. Background data refreshes that
  // keep the same key keep the current page instead.
  final Object? resetPageKey;
  // Stable identity per row (e.g. a Firestore doc id). When set, each
  // row's widgets are keyed by it, so stateful cells (a busy APPROVE
  // button, say) stay attached to the same record when rows re-sort or a
  // live stream reorders them, instead of being matched by position.
  final Object Function(T row)? rowKey;
  final DataTableController<T>? controller;

  const DataTableView({
    super.key,
    required this.columns,
    required this.rows,
    this.initialSortColumn,
    this.initialSortAscending = true,
    this.onRowTap,
    this.emptyState,
    this.pageSize = 25,
    this.pinnedColumns = 1,
    this.rowHeight = 52,
    this.headerHeight = 44,
    this.resetPageKey,
    this.rowKey,
    this.controller,
  }) : assert(pinnedColumns == 0 || pinnedColumns == 1);

  @override
  State<DataTableView<T>> createState() => _DataTableViewState<T>();
}

class _DataTableViewState<T> extends State<DataTableView<T>> {
  int? _sortColumn;
  bool _ascending = true;
  int _page = 0;
  final _hBody = ScrollController();
  final _hHeader = ScrollController();

  @override
  void initState() {
    super.initState();
    _sortColumn = widget.initialSortColumn;
    _ascending = widget.initialSortAscending;
    _hBody.addListener(_syncHeader);
    widget.controller?._state = this;
  }

  void _syncHeader() {
    if (_hHeader.hasClients && _hHeader.offset != _hBody.offset) {
      _hHeader.jumpTo(_hBody.offset.clamp(0.0, _hHeader.position.maxScrollExtent));
    }
  }

  @override
  void didUpdateWidget(covariant DataTableView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetPageKey != widget.resetPageKey) _page = 0;
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) oldWidget.controller!._state = null;
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    _hBody.removeListener(_syncHeader);
    _hBody.dispose();
    _hHeader.dispose();
    super.dispose();
  }

  List<T> get _sorted {
    final col = _sortColumn;
    final cmp = col == null ? null : widget.columns[col].compare;
    if (cmp == null) return widget.rows;
    // Stable: decorate with the original index as the final tie-break.
    final indexed = [for (var i = 0; i < widget.rows.length; i++) (i, widget.rows[i])];
    indexed.sort((a, b) {
      final c = cmp(a.$2, b.$2);
      if (c != 0) return _ascending ? c : -c;
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  void _onHeaderTap(int index) {
    if (widget.columns[index].compare == null) return;
    setState(() {
      if (_sortColumn == index) {
        _ascending = !_ascending;
      } else {
        _sortColumn = index;
        _ascending = true;
      }
      _page = 0;
    });
  }

  Widget _headerCell(int index, double width) {
    final c = widget.columns[index];
    final sortable = c.compare != null;
    final active = _sortColumn == index;
    final label = Text(
      c.label.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppText.caption.copyWith(
        fontWeight: FontWeight.w700,
        color: active ? AppColors.navy : AppColors.textSecondary,
        letterSpacing: 0.3,
      ),
    );
    return Semantics(
      button: sortable,
      label: sortable ? 'Sort by ${c.label}' : null,
      child: InkWell(
        key: ValueKey('dtv-header-$index'),
        onTap: sortable ? () => _onHeaderTap(index) : null,
        child: Container(
          width: width,
          height: widget.headerHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: label),
              if (sortable)
                Icon(
                  active
                      ? (_ascending ? Icons.arrow_upward : Icons.arrow_downward)
                      : Icons.unfold_more,
                  size: 14,
                  color: active ? AppColors.navy : AppColors.textMuted,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bodyCell(BuildContext context, int colIndex, T row, double width) {
    final c = widget.columns[colIndex];
    return Container(
      width: width,
      height: widget.rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
      child: DefaultTextStyle.merge(
        style: AppText.body.copyWith(fontSize: 13),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        child: c.cellBuilder(context, row),
      ),
    );
  }

  Color _rowColor(int i) => i.isOdd ? AppColors.background : AppColors.card;

  Widget _rowWrap({
    required int index,
    required T row,
    required List<Widget> cells,
    String part = '',
  }) {
    final tap = widget.onRowTap;
    final keyOf = widget.rowKey;
    return Material(
      key: keyOf == null ? null : ValueKey('dtv-row$part-${keyOf(row)}'),
      color: _rowColor(index),
      child: InkWell(
        onTap: tap == null ? null : () => tap(row),
        child: Row(mainAxisSize: MainAxisSize.min, children: cells),
      ),
    );
  }

  Widget _pager(int total, int pageCount) {
    final start = total == 0 ? 0 : _page * widget.pageSize + 1;
    final end = ((_page + 1) * widget.pageSize).clamp(0, total);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$start–$end of $total',
              key: const ValueKey('dtv-page-label'),
              style: AppText.caption,
            ),
          ),
          if (pageCount > 1) ...[
            IconButton(
              key: const ValueKey('dtv-prev'),
              tooltip: 'Previous page',
              icon: const Icon(Icons.chevron_left),
              onPressed: _page > 0 ? () => setState(() => _page--) : null,
            ),
            Text('${_page + 1} / $pageCount', style: AppText.caption),
            IconButton(
              key: const ValueKey('dtv-next'),
              tooltip: 'Next page',
              icon: const Icon(Icons.chevron_right),
              onPressed: _page < pageCount - 1 ? () => setState(() => _page++) : null,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) {
      return widget.emptyState ??
          const Center(
            child: Padding(padding: EdgeInsets.all(24), child: Text('No rows')),
          );
    }
    final sorted = _sorted;
    final total = sorted.length;
    final pageCount = (total + widget.pageSize - 1) ~/ widget.pageSize;
    if (_page > pageCount - 1) _page = pageCount - 1;
    final pageRows = sorted.skip(_page * widget.pageSize).take(widget.pageSize).toList();
    final pinned = widget.pinnedColumns.clamp(0, widget.columns.length);

    return LayoutBuilder(
      builder: (context, constraints) {
        final pinnedWidth = pinned == 0 ? 0.0 : widget.columns[0].width;
        final restIdx = [for (var i = pinned; i < widget.columns.length; i++) i];
        final restBase = restIdx.fold<double>(0, (s, i) => s + widget.columns[i].width);
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth - pinnedWidth
            : restBase;
        final scale = (available > restBase && restBase > 0) ? available / restBase : 1.0;
        double w(int i) => i < pinned ? widget.columns[i].width : widget.columns[i].width * scale;
        final restWidth = restBase * scale;

        final header = Container(
          decoration: const BoxDecoration(
            color: AppColors.primarySoft,
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              if (pinned == 1) _headerCell(0, w(0)),
              Expanded(
                child: SingleChildScrollView(
                  controller: _hHeader,
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Row(children: [for (final i in restIdx) _headerCell(i, w(i))]),
                ),
              ),
            ],
          ),
        );

        final body = SingleChildScrollView(
          // Always scrollable so a parent RefreshIndicator can still be
          // pulled when a page has only a few rows.
          physics: const AlwaysScrollableScrollPhysics(),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (pinned == 1)
                Container(
                  decoration: const BoxDecoration(
                    border: Border(right: BorderSide(color: AppColors.border)),
                  ),
                  child: Column(
                    children: [
                      for (var r = 0; r < pageRows.length; r++)
                        _rowWrap(
                          index: r,
                          row: pageRows[r],
                          part: 'p',
                          cells: [_bodyCell(context, 0, pageRows[r], w(0))],
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: Scrollbar(
                  controller: _hBody,
                  child: SingleChildScrollView(
                    controller: _hBody,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: restWidth,
                      child: Column(
                        children: [
                          for (var r = 0; r < pageRows.length; r++)
                            _rowWrap(
                              index: r,
                              row: pageRows[r],
                              cells: [
                                for (final i in restIdx) _bodyCell(context, i, pageRows[r], w(i)),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

        return Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              header,
              Expanded(child: body),
              _pager(total, pageCount),
            ],
          ),
        );
      },
    );
  }
}

// One status filter chip option for DataTableToolbar.
class DataTableFilterOption {
  final String value;
  final String label;
  final int? count;
  final Color? color;
  const DataTableFilterOption({required this.value, required this.label, this.count, this.color});
}

// Search box + status filter chips that sit above a DataTableView. Pure
// presentation — the caller owns the search text/selected filter and does
// the filtering, so it can reuse whatever matching rules it already had.
class DataTableToolbar extends StatelessWidget {
  final TextEditingController? searchController;
  final String searchHint;
  final ValueChanged<String>? onSearchChanged;
  final List<DataTableFilterOption> filters;
  final String? selectedFilter;
  final ValueChanged<String>? onFilterChanged;
  final bool upperCaseSearch;
  // Shows an EXPORT menu (PDF / Image (PNG)); called with
  // DataTableToolbar.exportPdf or DataTableToolbar.exportPng.
  final ValueChanged<String>? onExport;

  static const String exportPdf = 'pdf';
  static const String exportPng = 'png';

  const DataTableToolbar({
    super.key,
    this.searchController,
    this.searchHint = 'Search vehicle number',
    this.onSearchChanged,
    this.filters = const [],
    this.selectedFilter,
    this.onFilterChanged,
    this.upperCaseSearch = false,
    this.onExport,
  });

  Widget _exportMenu() {
    return PopupMenuButton<String>(
      key: const ValueKey('dtv-export'),
      tooltip: 'Export',
      onSelected: (v) => onExport?.call(v),
      itemBuilder: (_) => const [
        PopupMenuItem(
          key: ValueKey('dtv-export-pdf'),
          value: exportPdf,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.picture_as_pdf_outlined),
            title: Text('PDF'),
          ),
        ),
        PopupMenuItem(
          key: ValueKey('dtv-export-png'),
          value: exportPng,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.image_outlined),
            title: Text('Image (PNG)'),
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppRadius.button),
          color: AppColors.card,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.file_download_outlined, size: 18, color: AppColors.navy),
            const SizedBox(width: 6),
            Text('EXPORT', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final search = onSearchChanged == null
        ? null
        : TextField(
            controller: searchController,
            textCapitalization: upperCaseSearch
                ? TextCapitalization.characters
                : TextCapitalization.none,
            decoration: InputDecoration(
              hintText: searchHint,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
            ),
            onChanged: onSearchChanged,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (search != null && onExport != null)
          Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: AppSpacing.sm),
              _exportMenu(),
            ],
          )
        else if (search != null)
          search
        else if (onExport != null)
          Align(alignment: Alignment.centerRight, child: _exportMenu()),
        if (filters.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              for (final f in filters)
                ChoiceChip(
                  key: ValueKey('dtv-filter-${f.value}'),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(f.label),
                      if (f.count != null) ...[
                        const SizedBox(width: 6),
                        Text('${f.count}', style: const TextStyle(fontWeight: FontWeight.w400)),
                      ],
                    ],
                  ),
                  selected: selectedFilter == f.value,
                  selectedColor: (f.color ?? AppColors.primary).withValues(alpha: 0.18),
                  labelStyle: AppText.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: f.color ?? AppColors.textPrimary,
                  ),
                  onSelected: (_) => onFilterChanged?.call(f.value),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

// Small coloured status pill used in table cells.
class DataTableStatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const DataTableStatusChip({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
