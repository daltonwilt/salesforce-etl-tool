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
* Dalton Wilt      2026-11-06    Cover the remaining DataImportSpec paths.
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

    /**
     * With no override set, load reads Data_Import_Template__mdt by SOQL. A name with no
     * record must say so, rather than hand back a null spec for the batch to trip on.
     */
    @isTest
    static void load_noOverrideAndNoSuchRecord_throws() {
        DataImportSpec.jsonOverride = null;
        DataImportSpec.clearCache();

        try {
            DataImportSpec.load('No_Such_Template_Anywhere');
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(
                e.getMessage().contains('No import template named "No_Such_Template_Anywhere"'),
                e.getMessage()
            );
        }
    }

    @isTest
    static void load_definitionIsNotJson_throws() {
        register('this is not json');

        try {
            DataImportSpec.load(TEMPLATE);
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(e.getMessage().contains('is not valid JSON'), e.getMessage());
        }
    }

    /** The picker's list is the active templates, and only those. */
    @isTest
    static void available_templates_returnsOnlyTheActiveOnes() {
        Set<String> expected = new Set<String>();
        for (Data_Import_Template__mdt record : [
            SELECT DeveloperName
            FROM Data_Import_Template__mdt
            WHERE Active__c = true
        ]) {
            expected.add(record.DeveloperName);
        }

        Set<String> actual = new Set<String>();
        for (Data_Import_Template__mdt record : DataImportSpec.available()) {
            Assert.isTrue(record.Active__c, record.DeveloperName + ' is inactive');
            actual.add(record.DeveloperName);
        }

        Assert.areEqual(expected, actual);
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

    @isTest
    static void load_noSections_throws() {
        register(JSON.serialize(new Map<String, Object>{ 'label' => 'Empty' }));

        try {
            DataImportSpec.load(TEMPLATE);
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(e.getMessage().contains('no sections'), e.getMessage());
        }
    }

    /** Every fault in a template is reported on the one load, not one per fix and redeploy. */
    @isTest
    static void load_rowsSectionWithNoTargetColumnsOrStart_reportsEveryFault() {
        register(
            JSON.serialize(
                new Map<String, Object>{
                    'sections' => new List<Object>{
                        new Map<String, Object>{ 'type' => 'rows' }
                    }
                }
            )
        );

        try {
            DataImportSpec.load(TEMPLATE);
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            String message = e.getMessage();
            Assert.isTrue(message.contains('a rows section with no target'), message);
            Assert.isTrue(message.contains('a rows section with no columns'), message);
            Assert.isTrue(
                message.contains('a rows section with neither firstDataRow nor startsAfter'),
                message
            );
        }
    }

    @isTest
    static void load_unknownSectionType_throws() {
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
        ((List<Object>) definition.get('sections')).add(
            new Map<String, Object>{ 'type' => 'table' }
        );
        register(JSON.serialize(definition));

        try {
            DataImportSpec.load(TEMPLATE);
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(
                e.getMessage().contains('section type "table" is not "cells" or "rows"'),
                e.getMessage()
            );
        }
    }

    /**
     * With two tables the job's section map is the only way a chunk knows whose rows it
     * holds, so an unnamed table cannot be told apart. Reported once, however many lack a name.
     */
    @isTest
    static void load_twoUnnamedRowsSections_throwsOnce() {
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
        List<Object> sections = (List<Object>) definition.get('sections');
        sections.add(sections[0]);
        register(JSON.serialize(definition));

        try {
            DataImportSpec.load(TEMPLATE);
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.areEqual(
                1,
                e.getMessage().countMatches('every rows section needs a sectionName'),
                e.getMessage()
            );
        }
    }

    // ---------------- sections ----------------

    @isTest
    static void sectionNamed_unknownName_returnsNull() {
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
        ((Map<String, Object>) ((List<Object>) definition.get('sections'))[0])
            .put('sectionName', 'accounts');
        register(JSON.serialize(definition));

        DataImportSpec spec = DataImportSpec.load(TEMPLATE);

        Assert.areEqual('Account', spec.sectionNamed('accounts').target);
        Assert.isNull(spec.sectionNamed('contacts'));
    }

    /** A group declared without options reads no columns, and must not hide the others. */
    @isTest
    static void columnIndexes_groupWithNoOptions_isSkipped() {
        DataImportSpec.Grouping empty = new DataImportSpec.Grouping();
        empty.field = 'Description';
        DataImportSpec.Grouping grouping = new DataImportSpec.Grouping();
        grouping.field = 'Description';
        grouping.options = new Map<String, String>{ 'C' => 'Alpha' };
        DataImportSpec.Section section = new DataImportSpec.Section();
        section.columns = new Map<String, String>{ 'A' => 'Name' };
        section.groups = new List<DataImportSpec.Grouping>{ empty, grouping };

        Assert.areEqual(new Set<Integer>{ 0, 2 }, section.columnIndexes());
    }

    // ---------------- header depth ----------------

    /**
     * A table found by its marker has no firstDataRow, so its heading row is what sets the
     * depth - deeper here than the metadata block above it.
     */
    @isTest
    static void headerDepth_headingRowBelowTheCells_isTheHeadingRow() {
        register(
            JSON.serialize(
                new Map<String, Object>{
                    'sections' => new List<Object>{
                        new Map<String, Object>{
                            'type' => 'cells',
                            'applyTo' => 'defaults',
                            'cells' => new Map<String, String>{ 'B3' => 'Site' }
                        },
                        new Map<String, Object>{
                            'type' => 'rows',
                            'target' => 'Account',
                            'startsAfter' => 'Accounts',
                            'headerRow' => 5,
                            'columns' => new Map<String, String>{ 'A' => 'Name' }
                        }
                    }
                }
            )
        );

        DataImportSpec spec = DataImportSpec.load(TEMPLATE);

        Assert.areEqual(3, spec.cellRowDepth());
        Assert.areEqual(5, spec.headerDepth());
    }

    @isTest
    static void cellRowDepth_cellsSectionWithNoCells_contributesNothing() {
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
        ((List<Object>) definition.get('sections')).add(
            new Map<String, Object>{ 'type' => 'cells' }
        );
        register(JSON.serialize(definition));

        DataImportSpec spec = DataImportSpec.load(TEMPLATE);

        Assert.areEqual(0, spec.cellRowDepth());
        Assert.areEqual(1, spec.headerDepth(), 'the table\'s own heading row still counts');
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

    @isTest
    static void columnIndex_blank_returnsNull() {
        Assert.isNull(DataImportSpec.columnIndex(' '));
        Assert.isNull(DataImportSpec.columnIndex(null));
    }

    @isTest
    static void columnOf_rowOf_blankAddress_returnNull() {
        Assert.isNull(DataImportSpec.columnOf(''));
        Assert.isNull(DataImportSpec.rowOf(null));
    }
}