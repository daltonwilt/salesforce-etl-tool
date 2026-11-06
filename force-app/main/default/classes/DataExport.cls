/**********************************************************************************
* Name         : DataExport
* Author       : Dalton Wilt
* Desc         : Reads Data_Export__mdt / Data_Export_Sheet__mdt configuration and the
*                SObject data each sheet lists, for the c-data-export LWC. The
*                files themselves - Excel or CSV - are built in the browser (c/xlsx,
*                c/csv); this class only answers "which sheets, styled how" and
*                "what rows".
* Created On   : 2026-11-06
* Test classes : DataExportTest
*
* Sharing      : with sharing, and every data query runs in USER_MODE - an export
*                must never show a user a record or field they could not open in the
*                app. Columns the user cannot read are left out rather than failing
*                the sheet, because one configuration serves users with different
*                field access.
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-11-06    Initial implementation.
**********************************************************************************/

public with sharing class DataExport {
  @TestVisible
  private static final Integer DEFAULT_ROW_LIMIT = 10000;

  // The SOQL row limit for one transaction. Each sheet is its own call, so each gets all of it -
  // though on a wide sheet the 6 MB heap runs out first, which is why the default is lower.
  @TestVisible
  private static final Integer MAX_ROW_LIMIT = 50000;

  // A field path: API names joined by dots. Checked before anything reaches the query, so a typo
  // in configuration is reported as one rather than as a SOQL parse error.
  private static final Pattern FIELD_PATH = Pattern.compile(
    '^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$'
  );

  // ------------------------------------------------------------------
  // Inner Classes
  // ------------------------------------------------------------------

  /** An export as the component needs it: which sheets to fetch, and how to package them. */
  public class ExportDefinition {
    /** Data_Export__mdt label, for messages. */
    @AuraEnabled
    public String label;

    /** Bundle several files into one zip with this name; blank downloads each separately. */
    @AuraEnabled
    public String zipFileName;

    /** Styles__c: JSON styling for every sheet, already checked to parse. Null when blank. */
    @AuraEnabled
    public String styles;

    /** Every sheet, in Sort_Order__c order. */
    @AuraEnabled
    public List<SheetDefinition> sheets;
  }

  /** One sheet of an export, before its data is fetched. */
  public class SheetDefinition {
    /** What getSheetData takes back. */
    @AuraEnabled
    public String developerName;

    /** The sheet's tab name. */
    @AuraEnabled
    public String label;

    /** The file it belongs to; sheets sharing one share a workbook (as CSV, a name prefix). */
    @AuraEnabled
    public String fileName;

    /** Styles__c: JSON styling over the export's, already checked to parse. Null when blank. */
    @AuraEnabled
    public String styles;
  }

  /** One column of a sheet. */
  public class Column {
    /** Header text: the AS name from configuration, or the field's label. */
    @AuraEnabled
    public String label;

    /** Column type (c/export): text, number, integer, currency, percent, date, datetime or boolean. */
    @AuraEnabled
    public String type;

    /** The configured field path, e.g. Owner.Name. */
    @AuraEnabled
    public String fieldPath;
  }

  /** A sheet's columns and rows. Each row is a list of values in column order. */
  public class SheetData {
    @AuraEnabled
    public List<Column> columns;

    @AuraEnabled
    public List<List<Object>> rows;

    /** True when more records matched than the row limit let in. */
    @AuraEnabled
    public Boolean truncated;

    /** The limit applied, so the component can say where the sheet stopped. */
    @AuraEnabled
    public Integer rowLimit;
  }

  /** A column as configured, before it is checked against the schema. */
  @TestVisible
  private class ColumnSpec {
    @TestVisible
    String path;
    @TestVisible
    String header;
  }

  /** A column resolved against the schema. */
  private class ResolvedField {
    List<String> parts;
    String selectExpression;
    Column column;
    Boolean accessible;
  }

  // ------------------------------------------------------------------
  // Configuration
  // ------------------------------------------------------------------

  /**
   * The sheets an export is made of, in order.
   *
   * cacheable: configuration is deployed metadata, so it cannot change mid-session in any way a
   * user would expect to see without reloading.
   *
   * @param exportName an Data_Export__mdt DeveloperName
   * @return           the export and its sheets
   * @throws AuraHandledException when the name is blank, unknown, has no sheets, or its own or a
   *         sheet's Styles__c is not a JSON object
   */
  @AuraEnabled(cacheable=true)
  public static ExportDefinition getExport(String exportName) {
    if (String.isBlank(exportName)) {
      throw fail('An export name is required.');
    }
    Data_Export__mdt config = exportByName(exportName);
    if (config == null) {
      throw fail('There is no data export named "' + exportName + '".');
    }
    List<Data_Export_Sheet__mdt> sheets = sheetsOf(exportName);
    if (sheets.isEmpty()) {
      throw fail('The "' + config.MasterLabel + '" export has no sheets.');
    }

    ExportDefinition definition = new ExportDefinition();
    definition.label = config.MasterLabel;
    definition.zipFileName = config.Zip_File_Name__c;
    definition.styles = checkedStyles(
      config.Styles__c,
      'The "' + config.MasterLabel + '" export'
    );
    definition.sheets = new List<SheetDefinition>();
    for (Data_Export_Sheet__mdt sheet : sheets) {
      SheetDefinition item = new SheetDefinition();
      item.developerName = sheet.DeveloperName;
      item.label = sheet.MasterLabel;
      item.fileName = sheet.File_Name__c;
      item.styles = checkedStyles(
        sheet.Styles__c,
        'The "' + sheet.MasterLabel + '" sheet'
      );
      definition.sheets.add(item);
    }
    return definition;
  }

  // ------------------------------------------------------------------
  // Data
  // ------------------------------------------------------------------

  /**
   * One sheet's columns and rows, read as the running user.
   *
   * One call per sheet rather than one per export, so every sheet gets a transaction's full query
   * and heap limits, and the component can show progress between them. Not cacheable: an export is
   * expected to reflect the data as it is now.
   *
   * The Filter__c and Order_By__c clauses are inserted into the query as written. They come from
   * deployed metadata, which only an administrator can change, and never from the browser - the
   * browser sends a sheet name and a record Id, and the Id is a bind variable.
   *
   * @param sheetName an Data_Export_Sheet__mdt DeveloperName
   * @param recordId  the record the component is on, bound as :recordId in the filter; optional
   * @return          the sheet's columns, and its rows up to the row limit
   * @throws AuraHandledException when the sheet is unknown, its configuration names an object or
   *         field that does not exist, the user cannot read the object, or the query fails
   */
  @AuraEnabled
  public static SheetData getSheetData(String sheetName, Id recordId) {
    Data_Export_Sheet__mdt sheet = String.isBlank(sheetName)
      ? null
      : sheetByName(sheetName);
    if (sheet == null) {
      throw fail('There is no export sheet named "' + sheetName + '".');
    }

    Schema.DescribeSObjectResult objectDescribe = describeObject(sheet);
    if (!objectDescribe.isAccessible()) {
      throw fail(
        'You do not have access to ' +
          objectDescribe.getLabelPlural() +
          ', so the "' +
          sheet.MasterLabel +
          '" sheet cannot be built.'
      );
    }

    List<ResolvedField> fields = new List<ResolvedField>();
    for (ColumnSpec spec : parseFields(sheet.Fields__c)) {
      ResolvedField field = resolve(objectDescribe, spec, sheet.MasterLabel);
      if (field.accessible) {
        fields.add(field);
      }
    }
    if (fields.isEmpty()) {
      throw fail(
        'The "' + sheet.MasterLabel + '" sheet has no fields you have access to.'
      );
    }

    Integer rowLimit = rowLimitOf(sheet);
    List<SObject> records = query(
      sheet,
      objectDescribe,
      fields,
      rowLimit,
      recordId
    );

    SheetData data = new SheetData();
    data.columns = new List<Column>();
    for (ResolvedField field : fields) {
      data.columns.add(field.column);
    }
    data.rowLimit = rowLimit;
    data.truncated = records.size() > rowLimit;
    data.rows = new List<List<Object>>();
    Integer count = Math.min(records.size(), rowLimit);
    for (Integer i = 0; i < count; i++) {
      List<Object> row = new List<Object>();
      for (ResolvedField field : fields) {
        row.add(cellValue(records[i], field));
      }
      data.rows.add(row);
    }
    return data;
  }

  // ------------------------------------------------------------------
  // Query
  // ------------------------------------------------------------------

  private static List<SObject> query(
    Data_Export_Sheet__mdt sheet,
    Schema.DescribeSObjectResult objectDescribe,
    List<ResolvedField> fields,
    Integer rowLimit,
    Id recordId
  ) {
    // The same field may be listed twice under different headers, but SOQL refuses a duplicate.
    Set<String> seen = new Set<String>();
    List<String> selects = new List<String>();
    for (ResolvedField field : fields) {
      if (seen.add(field.selectExpression.toLowerCase())) {
        selects.add(field.selectExpression);
      }
    }

    String soql =
      'SELECT ' +
      String.join(selects, ', ') +
      ' FROM ' +
      objectDescribe.getName();
    if (String.isNotBlank(sheet.Filter__c)) {
      soql += ' WHERE ' + sheet.Filter__c.trim();
    }
    if (String.isNotBlank(sheet.Order_By__c)) {
      soql += ' ORDER BY ' + sheet.Order_By__c.trim();
    }
    // One past the limit, to tell a sheet that is exactly full from one that was cut short.
    soql += ' LIMIT ' + (rowLimit + 1);

    Map<String, Object> binds = new Map<String, Object>{
      'recordId' => recordId,
      'userId' => UserInfo.getUserId()
    };
    try {
      return Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
    } catch (Exception e) {
      throw fail(
        'The "' + sheet.MasterLabel + '" sheet could not be read: ' + e.getMessage()
      );
    }
  }

  /** The value at a field path, walking lookups; null when any lookup on the way is empty. */
  private static Object cellValue(SObject record, ResolvedField field) {
    SObject current = record;
    for (Integer i = 0; i < field.parts.size() - 1; i++) {
      current = current.getSObject(field.parts[i]);
      if (current == null) {
        return null;
      }
    }
    Object value = current.get(field.parts[field.parts.size() - 1]);
    // Salesforce stores 12.5% as 12.5; a spreadsheet's percent format expects 0.125.
    if (value != null && field.column.type == 'percent') {
      value = ((Decimal) value).divide(100, 10).stripTrailingZeros();
    }
    return value;
  }

  private static Integer rowLimitOf(Data_Export_Sheet__mdt sheet) {
    if (sheet.Row_Limit__c == null || sheet.Row_Limit__c < 1) {
      return DEFAULT_ROW_LIMIT;
    }
    return Math.min(sheet.Row_Limit__c.intValue(), MAX_ROW_LIMIT);
  }

  // ------------------------------------------------------------------
  // Fields
  // ------------------------------------------------------------------

  /**
   * The columns listed in Fields__c, in order: comma or line separated, each a field path with an
   * optional "AS Header".
   */
  @TestVisible
  private static List<ColumnSpec> parseFields(String fieldList) {
    List<ColumnSpec> specs = new List<ColumnSpec>();
    if (String.isBlank(fieldList)) {
      return specs;
    }
    for (String entry : fieldList.split('[,\\r\\n]+')) {
      if (String.isBlank(entry)) {
        continue;
      }
      List<String> pieces = entry.trim().split('(?i)\\s+as\\s+', 2);
      ColumnSpec spec = new ColumnSpec();
      spec.path = pieces[0].trim();
      spec.header = pieces.size() > 1 && String.isNotBlank(pieces[1])
        ? pieces[1].trim()
        : null;
      specs.add(spec);
    }
    return specs;
  }

  /**
   * A configured column checked against the schema: the field exists, every lookup on the way to
   * it exists, and whether the user can read all of them.
   */
  private static ResolvedField resolve(
    Schema.DescribeSObjectResult root,
    ColumnSpec spec,
    String sheetLabel
  ) {
    if (!FIELD_PATH.matcher(spec.path).matches()) {
      throw fail(
        'The "' +
          sheetLabel +
          '" sheet lists "' +
          spec.path +
          '", which is not a field name.'
      );
    }

    List<String> parts = spec.path.split('\\.');
    Schema.DescribeSObjectResult current = root;
    List<String> lookupLabels = new List<String>();
    Boolean accessible = true;

    for (Integer i = 0; i < parts.size() - 1; i++) {
      Schema.DescribeFieldResult lookup = relationshipsOf(current)
        .get(parts[i].toLowerCase());
      if (lookup == null) {
        throw fail(
          'The "' +
            sheetLabel +
            '" sheet lists "' +
            spec.path +
            '", but ' +
            current.getName() +
            ' has no relationship named "' +
            parts[i] +
            '".'
        );
      }
      accessible = accessible && lookup.isAccessible();
      lookupLabels.add(lookupLabel(lookup));
      current = targetOf(lookup, parts[i + 1]);
    }

    String fieldName = parts[parts.size() - 1];
    Schema.SObjectField token = current.fields.getMap().get(fieldName);
    if (token == null) {
      throw fail(
        'The "' +
          sheetLabel +
          '" sheet lists "' +
          spec.path +
          '", but ' +
          current.getName() +
          ' has no field named "' +
          fieldName +
          '".'
      );
    }
    Schema.DescribeFieldResult field = token.getDescribe();
    Schema.DisplayType displayType = field.getType();
    if (
      displayType == Schema.DisplayType.ADDRESS ||
      displayType == Schema.DisplayType.LOCATION
    ) {
      throw fail(
        'The "' +
          sheetLabel +
          '" sheet lists "' +
          spec.path +
          '", a compound field. List its parts instead, e.g. BillingCity or BillingPostalCode.'
      );
    }

    ResolvedField resolved = new ResolvedField();
    resolved.parts = parts;
    resolved.accessible = accessible && field.isAccessible();
    // toLabel so picklists read as the user sees them in the app - translated, and the label
    // rather than the API value where the two differ.
    resolved.selectExpression = displayType == Schema.DisplayType.PICKLIST ||
      displayType == Schema.DisplayType.MULTIPICKLIST
      ? 'toLabel(' + spec.path + ')'
      : spec.path;

    Column column = new Column();
    column.fieldPath = spec.path;
    column.type = columnType(displayType);
    if (spec.header != null) {
      column.label = spec.header;
    } else {
      lookupLabels.add(field.getLabel());
      // "Owner: Full Name", the way report builder names a field reached through a lookup.
      column.label = String.join(lookupLabels, ': ');
    }
    resolved.column = column;
    return resolved;
  }

  /** The column type (c/export) a field is written as. */
  @TestVisible
  private static String columnType(Schema.DisplayType displayType) {
    switch on displayType {
      when CURRENCY {
        return 'currency';
      }
      when PERCENT {
        return 'percent';
      }
      when INTEGER, LONG {
        return 'integer';
      }
      when DOUBLE {
        return 'number';
      }
      when DATE {
        return 'date';
      }
      when DATETIME {
        return 'datetime';
      }
      when BOOLEAN {
        return 'boolean';
      }
      when else {
        return 'text';
      }
    }
  }

  /** "Account ID" becomes "Account": the lookup's label, naming the record rather than its Id. */
  private static String lookupLabel(Schema.DescribeFieldResult lookup) {
    String label = lookup.getLabel();
    return label.endsWith(' ID') ? label.removeEnd(' ID') : label;
  }

  /**
   * The object a lookup leads to. A polymorphic lookup (Owner, What, Who) can lead to several; the
   * first that has the next part of the path is the one described.
   */
  private static Schema.DescribeSObjectResult targetOf(
    Schema.DescribeFieldResult lookup,
    String nextPart
  ) {
    List<Schema.SObjectType> targets = lookup.getReferenceTo();
    String next = nextPart.toLowerCase();
    for (Schema.SObjectType target : targets) {
      Schema.DescribeSObjectResult candidate = target.getDescribe();
      if (
        candidate.fields.getMap().containsKey(next) ||
        relationshipsOf(candidate).containsKey(next)
      ) {
        return candidate;
      }
    }
    return targets[0].getDescribe();
  }

  private static Map<String, Map<String, Schema.DescribeFieldResult>> relationshipCache = new Map<String, Map<String, Schema.DescribeFieldResult>>();

  /** An object's lookups, keyed by lower-cased relationship name (Owner, Account, Parent__r). */
  private static Map<String, Schema.DescribeFieldResult> relationshipsOf(
    Schema.DescribeSObjectResult objectDescribe
  ) {
    String key = objectDescribe.getName();
    if (!relationshipCache.containsKey(key)) {
      Map<String, Schema.DescribeFieldResult> byName = new Map<String, Schema.DescribeFieldResult>();
      for (Schema.SObjectField token : objectDescribe.fields.getMap().values()) {
        Schema.DescribeFieldResult field = token.getDescribe();
        if (field.getRelationshipName() != null) {
          byName.put(field.getRelationshipName().toLowerCase(), field);
        }
      }
      relationshipCache.put(key, byName);
    }
    return relationshipCache.get(key);
  }

  private static Schema.DescribeSObjectResult describeObject(
    Data_Export_Sheet__mdt sheet
  ) {
    String objectName = sheet.Object_API_Name__c == null
      ? ''
      : sheet.Object_API_Name__c.trim();
    try {
      return Schema.describeSObjects(new List<String>{ objectName })[0];
    } catch (Exception e) {
      throw fail(
        'The "' +
          sheet.MasterLabel +
          '" sheet lists records of "' +
          objectName +
          '", which is not an object in this org.'
      );
    }
  }

  // ------------------------------------------------------------------
  // Data_Export__mdt / Data_Export_Sheet__mdt reads
  // ------------------------------------------------------------------

  // Custom metadata cannot be inserted in a test, so tests supply records here instead.
  @TestVisible
  private static List<Data_Export__mdt> mockExports;

  @TestVisible
  private static List<Data_Export_Sheet__mdt> mockSheets;

  private static Data_Export__mdt exportByName(String exportName) {
    List<Data_Export__mdt> found;
    if (mockExports != null) {
      found = new List<Data_Export__mdt>();
      for (Data_Export__mdt config : mockExports) {
        if (config.DeveloperName == exportName) {
          found.add(config);
        }
      }
    } else {
      found = [
        SELECT DeveloperName, MasterLabel, Zip_File_Name__c, Styles__c
        FROM Data_Export__mdt
        WHERE DeveloperName = :exportName
        LIMIT 1
      ];
    }
    return found.isEmpty() ? null : found[0];
  }

  /**
   * Every sheet of an export, in order. The mock returns all mock sheets: an in-memory metadata
   * record cannot carry the relationship to its export.
   */
  private static List<Data_Export_Sheet__mdt> sheetsOf(String exportName) {
    if (mockSheets != null) {
      return mockSheets;
    }
    return [
      SELECT
        DeveloperName,
        MasterLabel,
        File_Name__c,
        Sort_Order__c,
        Styles__c
      FROM Data_Export_Sheet__mdt
      WHERE Data_Export__r.DeveloperName = :exportName
      ORDER BY Sort_Order__c ASC NULLS LAST, MasterLabel ASC
    ];
  }

  private static Data_Export_Sheet__mdt sheetByName(String sheetName) {
    List<Data_Export_Sheet__mdt> found;
    if (mockSheets != null) {
      found = new List<Data_Export_Sheet__mdt>();
      for (Data_Export_Sheet__mdt sheet : mockSheets) {
        if (sheet.DeveloperName == sheetName) {
          found.add(sheet);
        }
      }
    } else {
      found = [
        SELECT
          DeveloperName,
          MasterLabel,
          File_Name__c,
          Object_API_Name__c,
          Fields__c,
          Filter__c,
          Order_By__c,
          Row_Limit__c
        FROM Data_Export_Sheet__mdt
        WHERE DeveloperName = :sheetName
        LIMIT 1
      ];
    }
    return found.isEmpty() ? null : found[0];
  }

  // ------------------------------------------------------------------
  // Support Methods
  // ------------------------------------------------------------------

  /**
   * A Styles__c value, checked here so a typo in configuration is reported against the record it
   * is on rather than surfacing as a parse error in the browser. The JSON is passed on as written;
   * what its keys mean is c/xlsx's business.
   *
   * @return the trimmed JSON, or null when blank
   * @throws AuraHandledException when it is not a JSON object
   */
  @TestVisible
  private static String checkedStyles(String styles, String owner) {
    if (String.isBlank(styles)) {
      return null;
    }
    Object parsed;
    try {
      parsed = JSON.deserializeUntyped(styles);
    } catch (JSONException e) {
      throw fail(owner + ' has Styles that are not valid JSON: ' + e.getMessage());
    }
    if (!(parsed instanceof Map<String, Object>)) {
      throw fail(owner + ' has Styles that are not a JSON object ({ ... }).');
    }
    return styles.trim();
  }

  /** An AuraHandledException whose getMessage() is the message too, so tests can read it. */
  private static AuraHandledException fail(String message) {
    AuraHandledException e = new AuraHandledException(message);
    e.setMessage(message);
    return e;
  }
}
