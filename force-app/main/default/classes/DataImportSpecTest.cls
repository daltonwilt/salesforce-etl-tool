/**********************************************************************************
* Name         : DataImportSpecTest
* Author       : Dalton Wilt
* Desc         : Tests for DataImportSpec - loading a template definition,
*                validating it, and the column-letter arithmetic every section
*                depends on.
*
*                Custom Metadata records cannot be inserted from Apex, so templates
*                come through DataImportSpec.jsonOverride. That is the only route
*                a test has, and every suite in this framework uses it.
*
*                A broken template is a coding mistake rather than a bad upload, so
*                the rejections below all have to happen on load - not at row 40,000
*                in front of whoever sent the file.
* Created On   : 2026-08-20
*
* Class under test : DataImportSpec
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-20    Split out of DataImportFrameworkTest.
**********************************************************************************/

@isTest
private class DataImportSpecTest {

    private static final String TEMPLATE = 'TestAccounts';

    /**
     * A plain table: headings on row 1, data from row 2. The shape most templates
     * have. Account is the target throughout this framework's suites - the claim is
     * that it loads any object from any template, so binding a test to one program's
     * schema would prove the wrong thing.
     */
    private static String simpleTemplate() {
        return JSON.serialize(
            new Map<String, Object>{
                'label' => 'Test Accounts',
                'sections' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'rows',
                        'target' => 'Account',
                        'headerRow' => 1,
                        'firstDataRow' => 2,
                        'columns' => new Map<String, String>{
                            'A' => 'Name',
                            'B' => 'AccountNumber',
                            'C' => 'NumberOfEmployees'
                        }
                    }
                }
            }
        );
    }

    private static void register(String json) {
        DataImportSpec.jsonOverride = new Map<String, String>{ TEMPLATE => json };
        DataImportSpec.clearCache();
    }

    // ---------------- load ----------------

    @isTest
    static void load_validTemplate_exposesLabelAndDefaults() {
        register(simpleTemplate());

        DataImportSpec spec = DataImportSpec.load(TEMPLATE);

        Assert.areEqual('Test Accounts', spec.label);
        Assert.areEqual(1, spec.rowSections().size());
        Assert.isTrue(spec.isAllOrNothing(), 'all or nothing is the default');
        Assert.areEqual(DataImportSpec.DEFAULT_ABORT_AFTER, spec.abortThreshold());
    }

    @isTest
    static void load_sameTemplateTwice_returnsTheCachedInstance() {
        register(simpleTemplate());

        DataImportSpec spec = DataImportSpec.load(TEMPLATE);
        DataImportSpec again = DataImportSpec.load(TEMPLATE);

        Assert.isTrue(spec == again, 'the second load must come from cache');
    }

    // ---------------- validation ----------------

    /** A broken template is a coding mistake, and must fail on load rather than at row 40,000. */
    @isTest
    static void load_noRowsSection_throws() {
        register(
            JSON.serialize(
                new Map<String, Object>{
                    'sections' => new List<Object>{
                        new Map<String, Object>{
                            'type' => 'cells',
                            'cells' => new Map<String, String>{ 'A1' => 'Name' }
                        }
                    }
                }
            )
        );

        try {
            DataImportSpec.load(TEMPLATE);
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(e.getMessage().contains('nothing would be imported'), e.getMessage());
        }
    }

    @isTest
    static void load_targetObjectDoesNotExist_throws() {
        register(simpleTemplate().replace('"Account"', '"Not_An_Object__c"'));

        try {
            DataImportSpec.load(TEMPLATE);
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(e.getMessage().contains('not an object'), e.getMessage());
        }
    }

    // ---------------- column addresses ----------------

    @isTest
    static void columnIndex_letters_convertToAZeroBasedIndex() {
        Assert.areEqual(0, DataImportSpec.columnIndex('A'));
        Assert.areEqual(26, DataImportSpec.columnIndex('AA'));
    }

    @isTest
    static void columnOf_rowOf_address_splitIntoColumnAndRow() {
        Assert.areEqual(5, DataImportSpec.columnOf('F12'));
        Assert.areEqual(12, DataImportSpec.rowOf('F12'));
    }

    @isTest
    static void columnIndex_notALetter_returnsNull() {
        Assert.isNull(DataImportSpec.columnIndex('4'));
    }
}