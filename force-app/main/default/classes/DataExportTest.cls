/**********************************************************************************
* Name         : DataExportTest
* Author       : Dalton Wilt
* Desc         : Tests for DataExport.
*
*                Data_Export__mdt and Data_Export_Sheet__mdt cannot be inserted in test
*                context, so configuration is assigned to the controller's
*                mockExports / mockSheets. The unknown-name tests leave them null so
*                the real metadata queries still execute.
* Created On   : 2026-11-06
*
* Class under test : DataExport
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-11-06    Initial implementation.
**********************************************************************************/

@isTest
public class DataExportTest {
  private static Data_Export__mdt export(String developerName, String zipName) {
    return new Data_Export__mdt(
      DeveloperName = developerName,
      MasterLabel = developerName,
      Zip_File_Name__c = zipName
    );
  }

  private static Data_Export_Sheet__mdt sheet(
    String developerName,
    String objectName,
    String fields,
    String filter
  ) {
    return new Data_Export_Sheet__mdt(
      DeveloperName = developerName,
      MasterLabel = developerName,
      File_Name__c = 'Book',
      Object_API_Name__c = objectName,
      Fields__c = fields,
      Filter__c = filter
    );
  }

  private static void useSheets(List<Data_Export_Sheet__mdt> sheets) {
    DataExport.mockSheets = sheets;
  }

  private static String failureOf(String sheetName, Id recordId) {
    try {
      DataExport.getSheetData(sheetName, recordId);
    } catch (AuraHandledException e) {
      return e.getMessage();
    }
    System.assert(false, 'expected getSheetData to throw');
    return null;
  }

  @TestSetup
  static void makeData() {
    Account acme = new Account(
      Name = 'Acme',
      Industry = 'Banking',
      AnnualRevenue = 1500000,
      NumberOfEmployees = 120
    );
    Account globex = new Account(Name = 'Globex', Industry = 'Energy');
    insert new List<Account>{ acme, globex };
    insert new List<Contact>{
      new Contact(LastName = 'Ng', AccountId = acme.Id),
      new Contact(LastName = 'Ortiz', AccountId = acme.Id),
      new Contact(LastName = 'Park')
    };
  }

  // ---------------- getExport ----------------

  @isTest
  static void getExport_returnsSheetsInOrderWithTheirFiles() {
    DataExport.mockExports = new List<Data_Export__mdt>{
      export('Overview', 'Overview {date}')
    };
    Data_Export_Sheet__mdt accounts = sheet('Accounts', 'Account', 'Name', null);
    Data_Export_Sheet__mdt contacts = sheet('Contacts', 'Contact', 'Name', null);
    contacts.File_Name__c = 'People';
    useSheets(new List<Data_Export_Sheet__mdt>{ accounts, contacts });

    DataExport.ExportDefinition definition = DataExport.getExport(
      'Overview'
    );

    System.assertEquals('Overview', definition.label);
    System.assertEquals('Overview {date}', definition.zipFileName);
    System.assertEquals(2, definition.sheets.size());
    System.assertEquals('Accounts', definition.sheets[0].developerName);
    System.assertEquals('Accounts', definition.sheets[0].label);
    System.assertEquals('Book', definition.sheets[0].fileName);
    System.assertEquals('People', definition.sheets[1].fileName);
  }

  @isTest
  static void getExport_passesStylesThroughAndReportsBadJsonByRecord() {
    Data_Export__mdt config = export('Styled', null);
    config.Styles__c = ' {"header": {"font": {"bold": true}}} ';
    DataExport.mockExports = new List<Data_Export__mdt>{ config };
    Data_Export_Sheet__mdt accounts = sheet('Accounts', 'Account', 'Name', null);
    accounts.Styles__c = '{"tabColor": "FF0B5CAB"}';
    Data_Export_Sheet__mdt contacts = sheet('Contacts', 'Contact', 'Name', null);
    useSheets(new List<Data_Export_Sheet__mdt>{ accounts, contacts });

    DataExport.ExportDefinition definition = DataExport.getExport(
      'Styled'
    );
    System.assertEquals('{"header": {"font": {"bold": true}}}', definition.styles);
    System.assertEquals('{"tabColor": "FF0B5CAB"}', definition.sheets[0].styles);
    System.assertEquals(null, definition.sheets[1].styles, 'blank styles come back null');

    contacts.Styles__c = '{"header": ';
    try {
      DataExport.getExport('Styled');
      System.assert(false, 'expected a failure');
    } catch (AuraHandledException e) {
      System.assert(
        e.getMessage().startsWith('The "Contacts" sheet has Styles that are not valid JSON'),
        e.getMessage()
      );
    }
  }

  @isTest
  static void checkedStyles_wantsAJsonObject() {
    System.assertEquals(null, DataExport.checkedStyles('  ', 'X'));
    try {
      DataExport.checkedStyles('[1, 2]', 'The "X" export');
      System.assert(false, 'expected a failure');
    } catch (AuraHandledException e) {
      System.assert(e.getMessage().contains('not a JSON object'), e.getMessage());
    }
  }

  @isTest
  static void getExport_refusesABlankOrUnknownName() {
    for (String name : new List<String>{ null, '', 'No_Such_Export_Xyz' }) {
      try {
        DataExport.getExport(name);
        System.assert(false, 'expected a failure for ' + name);
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('export name') ||
          e.getMessage().contains('no data export'),
          e.getMessage()
        );
      }
    }
  }

  @isTest
  static void getExport_refusesAnExportWithNoSheets() {
    DataExport.mockExports = new List<Data_Export__mdt>{
      export('Empty', null)
    };
    useSheets(new List<Data_Export_Sheet__mdt>());

    try {
      DataExport.getExport('Empty');
      System.assert(false, 'expected a failure');
    } catch (AuraHandledException e) {
      System.assert(e.getMessage().contains('has no sheets'), e.getMessage());
    }
  }

  // ---------------- getSheetData ----------------

  @isTest
  static void getSheetData_returnsTypedColumnsAndRowsInOrder() {
    useSheets(
      new List<Data_Export_Sheet__mdt>{
        sheet(
          'Accounts',
          'Account',
          'Name, Industry,\nAnnualRevenue, NumberOfEmployees, CreatedDate, Owner.Name',
          'Name = \'Acme\''
        )
      }
    );

    DataExport.SheetData data = DataExport.getSheetData(
      'Accounts',
      null
    );

    List<String> types = new List<String>();
    for (DataExport.Column column : data.columns) {
      types.add(column.type);
    }
    System.assertEquals(
      new List<String>{ 'text', 'text', 'currency', 'integer', 'datetime', 'text' },
      types
    );
    System.assertEquals('Owner.Name', data.columns[5].fieldPath);
    System.assert(
      data.columns[5].label.contains(': '),
      'a field through a lookup is named after the lookup: ' + data.columns[5].label
    );

    System.assertEquals(1, data.rows.size());
    List<Object> row = data.rows[0];
    System.assertEquals('Acme', row[0]);
    System.assertEquals('Banking', row[1], 'picklists come back as their label');
    System.assertEquals(1500000, (Decimal) row[2]);
    System.assertEquals(120, (Integer) row[3]);
    System.assertNotEquals(null, row[4]);
    System.assertEquals(UserInfo.getName(), row[5]);
    System.assertEquals(false, data.truncated);
  }

  @isTest
  static void getSheetData_usesTheHeaderGivenWithAs() {
    useSheets(
      new List<Data_Export_Sheet__mdt>{
        sheet('Accounts', 'Account', 'Name AS Company, Owner.Name as Account Owner', null)
      }
    );

    DataExport.SheetData data = DataExport.getSheetData(
      'Accounts',
      null
    );

    System.assertEquals('Company', data.columns[0].label);
    System.assertEquals('Account Owner', data.columns[1].label);
  }

  @isTest
  static void getSheetData_bindsTheRecordIdInTheFilter() {
    Id acmeId = [SELECT Id FROM Account WHERE Name = 'Acme'].Id;
    useSheets(
      new List<Data_Export_Sheet__mdt>{
        sheet('Contacts', 'Contact', 'LastName, Account.Name', 'AccountId = :recordId')
      }
    );
    DataExport.mockSheets[0].Order_By__c = 'LastName';

    DataExport.SheetData data = DataExport.getSheetData(
      'Contacts',
      acmeId
    );

    System.assertEquals(2, data.rows.size());
    System.assertEquals('Ng', data.rows[0][0]);
    System.assertEquals('Ortiz', data.rows[1][0]);
    System.assertEquals('Acme', data.rows[0][1]);
  }

  @isTest
  static void getSheetData_leavesAnEmptyLookupBlank() {
    useSheets(
      new List<Data_Export_Sheet__mdt>{
        sheet('Contacts', 'Contact', 'LastName, Account.Name', 'LastName = \'Park\'')
      }
    );

    DataExport.SheetData data = DataExport.getSheetData(
      'Contacts',
      null
    );

    System.assertEquals(null, data.rows[0][1]);
  }

  @isTest
  static void getSheetData_selectsARepeatedFieldOnce() {
    useSheets(
      new List<Data_Export_Sheet__mdt>{
        sheet('Accounts', 'Account', 'Name, Name AS Again', 'Name = \'Acme\'')
      }
    );

    DataExport.SheetData data = DataExport.getSheetData(
      'Accounts',
      null
    );

    System.assertEquals(2, data.columns.size());
    System.assertEquals('Acme', data.rows[0][1]);
  }

  @isTest
  static void getSheetData_stopsAtTheRowLimitAndSaysSo() {
    Data_Export_Sheet__mdt accounts = sheet('Accounts', 'Account', 'Name', null);
    accounts.Row_Limit__c = 1;
    accounts.Order_By__c = 'Name';
    useSheets(new List<Data_Export_Sheet__mdt>{ accounts });

    DataExport.SheetData data = DataExport.getSheetData(
      'Accounts',
      null
    );

    System.assertEquals(1, data.rows.size());
    System.assertEquals('Acme', data.rows[0][0]);
    System.assertEquals(true, data.truncated);
    System.assertEquals(1, data.rowLimit);
  }

  @isTest
  static void getSheetData_defaultsAndCapsTheRowLimit() {
    Data_Export_Sheet__mdt accounts = sheet('Accounts', 'Account', 'Name', null);
    useSheets(new List<Data_Export_Sheet__mdt>{ accounts });

    System.assertEquals(
      DataExport.DEFAULT_ROW_LIMIT,
      DataExport.getSheetData('Accounts', null).rowLimit
    );

    accounts.Row_Limit__c = 99999;
    System.assertEquals(
      DataExport.MAX_ROW_LIMIT,
      DataExport.getSheetData('Accounts', null).rowLimit
    );
  }

  @isTest
  static void getSheetData_reportsConfigurationMistakesByName() {
    useSheets(
      new List<Data_Export_Sheet__mdt>{
        sheet('BadObject', 'Not_An_Object__c', 'Name', null),
        sheet('BadField', 'Account', 'Name, Nope__c', null),
        sheet('BadLookup', 'Account', 'Nowhere.Name', null),
        sheet('BadPath', 'Account', 'Name; DELETE', null),
        sheet('Compound', 'Account', 'BillingAddress', null),
        sheet('BadFilter', 'Account', 'Name', 'Name ==== 1'),
        sheet('NoFields', 'Account', ' , ', null)
      }
    );

    System.assert(failureOf('BadObject', null).contains('not an object'));
    System.assert(failureOf('BadField', null).contains('no field named "Nope__c"'));
    System.assert(failureOf('BadLookup', null).contains('no relationship named "Nowhere"'));
    System.assert(failureOf('BadPath', null).contains('not a field name'));
    System.assert(failureOf('Compound', null).contains('compound field'));
    System.assert(failureOf('BadFilter', null).contains('could not be read'));
    System.assert(failureOf('NoFields', null).contains('no fields you have access to'));
  }

  @isTest
  static void getSheetData_refusesAnUnknownSheet() {
    System.assert(failureOf('No_Such_Sheet_Xyz', null).contains('no export sheet'));
    System.assert(failureOf(null, null).contains('no export sheet'));
  }

  @isTest
  static void getSheetData_refusesAnObjectTheUserCannotRead() {
    List<Profile> minimum = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Minimum Access - Salesforce'
      LIMIT 1
    ];
    if (minimum.isEmpty()) {
      return; // the profile is standard but renamable; without it there is no user to try
    }
    User restricted = new User(
      ProfileId = minimum[0].Id,
      LastName = 'Restricted',
      Email = 'restricted@example.com',
      Username = 'restricted' + System.currentTimeMillis() + '@example.com',
      Alias = 'rstr',
      TimeZoneSidKey = 'America/New_York',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
    insert restricted;
    useSheets(
      new List<Data_Export_Sheet__mdt>{ sheet('Accounts', 'Account', 'Name', null) }
    );

    System.runAs(restricted) {
      System.assert(failureOf('Accounts', null).contains('do not have access'));
    }
  }

  // ---------------- Fields__c parsing and types ----------------

  @isTest
  static void parseFields_splitsOnCommasAndLinesAndReadsHeaders() {
    List<DataExport.ColumnSpec> specs = DataExport.parseFields(
      ' Name ,\r\nOwner.Name AS Owner\n\nCreatedDate as  Created On, '
    );

    System.assertEquals(3, specs.size());
    System.assertEquals('Name', specs[0].path);
    System.assertEquals(null, specs[0].header);
    System.assertEquals('Owner.Name', specs[1].path);
    System.assertEquals('Owner', specs[1].header);
    System.assertEquals('Created On', specs[2].header);
    System.assertEquals(0, DataExport.parseFields(null).size());
  }

  @isTest
  static void columnType_mapsEachFieldType() {
    System.assertEquals('currency', DataExport.columnType(Schema.DisplayType.CURRENCY));
    System.assertEquals('percent', DataExport.columnType(Schema.DisplayType.PERCENT));
    System.assertEquals('integer', DataExport.columnType(Schema.DisplayType.INTEGER));
    System.assertEquals('integer', DataExport.columnType(Schema.DisplayType.LONG));
    System.assertEquals('number', DataExport.columnType(Schema.DisplayType.DOUBLE));
    System.assertEquals('date', DataExport.columnType(Schema.DisplayType.DATE));
    System.assertEquals('datetime', DataExport.columnType(Schema.DisplayType.DATETIME));
    System.assertEquals('boolean', DataExport.columnType(Schema.DisplayType.BOOLEAN));
    System.assertEquals('text', DataExport.columnType(Schema.DisplayType.PICKLIST));
  }

  @isTest
  static void getSheetData_writesPercentsAsFractions() {
    Opportunity opp = new Opportunity(
      Name = 'Deal',
      StageName = 'Prospecting',
      CloseDate = Date.today(),
      Probability = 25
    );
    insert opp;
    useSheets(
      new List<Data_Export_Sheet__mdt>{
        sheet('Opps', 'Opportunity', 'Name, Probability, CloseDate', 'Id = :recordId')
      }
    );

    DataExport.SheetData data = DataExport.getSheetData(
      'Opps',
      opp.Id
    );

    System.assertEquals('percent', data.columns[1].type);
    System.assertEquals(0.25, (Decimal) data.rows[0][1]);
    System.assertEquals('date', data.columns[2].type);
    System.assertEquals(Date.today(), (Date) data.rows[0][2]);
  }
}
