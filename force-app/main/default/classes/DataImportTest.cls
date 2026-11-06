/**********************************************************************************
* Name         : DataImportTest
* Author       : Dalton Wilt
* Desc         : Tests for DataImport - the shared parse and coercion helper, and
*                nothing above it. The layers that use it have their own suites.
*
*                The parts worth pinning are the ones a recipient's file actually
*                breaks on: quoted cells with commas and newlines in them (every
*                template's instruction block is one), and the currency, date and
*                picklist text Excel leaves behind.
*
*                Opportunity stands in as the coerced object - it carries one field
*                of each DisplayType this handles, so the coercion tests need no
*                second object and nothing configured for a program.
* Created On   : 2026-08-20
*
* Class under test : DataImport
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-20    Split out of DataImportHelperTest.
* Dalton Wilt      2026-08-20    Coerced object moved from SF_428S_Equipment__c to
*                                Opportunity, so the suite rests on no program schema.
* Dalton Wilt      2026-11-06    Cover the remaining DataImport paths.
**********************************************************************************/

@isTest
private class DataImportTest {

    private static DataImport.Coercer coercer() {
        return new DataImport.Coercer(Opportunity.SObjectType);
    }

    /**
     * A live StageName value, read off the picklist rather than written in. Which values
     * a stage picklist holds is org configuration, so naming one here would turn the two
     * picklist tests into configuration tests.
     */
    private static String stage() {
        for (Schema.PicklistEntry entry : Opportunity.StageName.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static Id uploadFile(String name, String body) {
        ContentVersion version = new ContentVersion(
            Title = name,
            PathOnClient = name,
            VersionData = Blob.valueOf(body)
        );
        insert version;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
    }

    // ---------------- parse ----------------

    @isTest
    static void parse_plainRows_readsEveryRow() {
        List<List<String>> rows = DataImport.parse('a,b,c\n1,2,3');

        Assert.areEqual(2, rows.size());
        Assert.areEqual(new List<String>{ '1', '2', '3' }, rows[1]);
    }

    /** Trailing empty cells must survive: a column index has to keep meaning the same column. */
    @isTest
    static void parse_trailingEmptyCells_keepsColumnCount() {
        List<List<String>> rows = DataImport.parse('a,b,c\n1,,');

        Assert.areEqual(3, rows[1].size());
        Assert.areEqual('', rows[1][2]);
    }

    @isTest
    static void parse_quotedComma_staysOneCell() {
        List<List<String>> rows = DataImport.parse('a,"one, two",c');

        Assert.areEqual(3, rows[0].size());
        Assert.areEqual('one, two', rows[0][1]);
    }

    /**
     * The case Parse_CSV_Utility cannot do, and the reason this parser exists: the
     * instruction block at the top of every template is a single quoted cell
     * spanning ten lines.
     */
    @isTest
    static void parse_newlineInsideQuotes_staysOneCell() {
        List<List<String>> rows = DataImport.parse(
            'Instructions: "line one\nline two\nline three",x\nnext,row'
        );

        Assert.areEqual(2, rows.size(), 'the quoted cell must not split into rows');
        Assert.areEqual('Instructions: line one\nline two\nline three', rows[0][0]);
        Assert.areEqual(new List<String>{ 'next', 'row' }, rows[1]);
    }

    @isTest
    static void parse_doubledQuotes_unescapesToOne() {
        List<List<String>> rows = DataImport.parse('"He said ""go"" twice",b');

        Assert.areEqual('He said "go" twice', rows[0][0]);
    }

    @isTest
    static void parse_crlfAndBareCr_bothSplitRows() {
        Assert.areEqual(2, DataImport.parse('a,b\r\nc,d').size());
        Assert.areEqual(2, DataImport.parse('a,b\rc,d').size());
    }

    /** An unterminated quote is a damaged file - take the row rather than silently dropping it. */
    @isTest
    static void parse_unterminatedQuote_keepsFinalRow() {
        List<List<String>> rows = DataImport.parse('a,b\n"unterminated,c');

        Assert.areEqual(2, rows.size());
    }

    @isTest
    static void parse_emptyInput_returnsNoRows() {
        Assert.areEqual(0, DataImport.parse('').size());
        Assert.areEqual(0, DataImport.parse(null).size());
    }

    // ---------------- cell / isRowBlank / isYes ----------------

    /** Excel drops trailing empty columns, so a short row is normal rather than an error. */
    @isTest
    static void cell_pastEndOfRow_returnsBlank() {
        List<String> row = new List<String>{ ' padded ' };

        Assert.areEqual('padded', DataImport.cell(row, 0), 'cells are trimmed');
        Assert.areEqual('', DataImport.cell(row, 9));
        Assert.areEqual('', DataImport.cell(null, 0));
    }

    /**
     * Blankness is judged only on the mapped columns. Templates carry legend and
     * row-counter columns that are populated on every line and are not data -
     * judging the whole row would import them.
     */
    @isTest
    static void isRowBlank_onlyGivenColumns_ignoresTheRest() {
        List<String> row = new List<String>{ 'legend', '1', '', '' };

        Assert.isTrue(DataImport.isRowBlank(row, new Set<Integer>{ 2, 3 }));
        Assert.isFalse(DataImport.isRowBlank(row, new Set<Integer>{ 0, 2 }));
    }

    @isTest
    static void isYes_anyAffirmativeMark_isTrue() {
        for (String marked : new List<String>{ 'Yes', 'y', 'TRUE', 'X', '1', ' yes ' }) {
            Assert.isTrue(DataImport.isYes(marked), marked + ' should read as Yes');
        }
    }

    /** Anything unrecognised is No: these columns select an option, so a stray mark must not set one. */
    @isTest
    static void isYes_unrecognisedMark_isFalse() {
        for (String marked : new List<String>{ 'No', 'n', '0', '', null, 'maybe' }) {
            Assert.isFalse(DataImport.isYes(marked), marked + ' should not read as Yes');
        }
    }

    // ---------------- Coercer.coerce ----------------

    @isTest
    static void coerce_dateInEitherFormat_returnsDate() {
        List<String> errors = new List<String>();
        DataImport.Coercer c = coercer();

        Assert.areEqual(
            Date.newInstance(2026, 3, 9),
            c.coerce('CloseDate', '03/09/2026', 'Row 8', errors)
        );
        Assert.areEqual(
            Date.newInstance(2026, 3, 9),
            c.coerce('CloseDate', '2026-03-09', 'Row 8', errors)
        );
        Assert.areEqual(0, errors.size());
    }

    @isTest
    static void coerce_unreadableDate_reportsRowAndColumn() {
        List<String> errors = new List<String>();

        Object value = coercer().coerce('CloseDate', 'last March', 'Row 8', errors);

        Assert.isNull(value);
        Assert.areEqual(1, errors.size());
        Assert.isTrue(errors[0].startsWith('Row 8, '), errors[0]);
        Assert.isTrue(errors[0].contains('last March'), errors[0]);
    }

    /** A Date/Time column takes the same MM/DD/YYYY a recipient types, as midnight on that day. */
    @isTest
    static void coerce_dateIntoDatetimeField_returnsMidnight() {
        List<String> errors = new List<String>();

        Object value = coercer().coerce('CreatedDate', '03/09/2026', 'Row 8', errors);

        Assert.areEqual(
            Datetime.newInstance(Date.newInstance(2026, 3, 9), Time.newInstance(0, 0, 0, 0)),
            value
        );
        Assert.areEqual(0, errors.size());
    }

    @isTest
    static void coerce_unreadableDatetime_reportsRowAndColumn() {
        List<String> errors = new List<String>();

        Object value = coercer().coerce('CreatedDate', 'last March', 'Row 8', errors);

        Assert.isNull(value);
        Assert.areEqual(1, errors.size());
        Assert.isTrue(errors[0].startsWith('Row 8, '), errors[0]);
        Assert.isTrue(errors[0].contains('is not a date'), errors[0]);
    }

    /** Currency columns arrive as text, so they carry whatever Excel formatted them with. */
    @isTest
    static void coerce_currencyAsExcelLeavesIt_returnsDecimal() {
        List<String> errors = new List<String>();
        DataImport.Coercer c = coercer();

        Assert.areEqual(12500.50, c.coerce('Amount', '$12,500.50', 'Row 8', errors));
        Assert.areEqual(
            -400,
            c.coerce('Amount', '(400)', 'Row 8', errors),
            'accounting parentheses are negative'
        );
        Assert.areEqual(0, errors.size());
    }

    @isTest
    static void coerce_percentSign_returnsNumber() {
        List<String> errors = new List<String>();

        Assert.areEqual(75, coercer().coerce('Probability', '75%', 'Row 8', errors));
        Assert.areEqual(0, errors.size());
    }

    @isTest
    static void coerce_unreadableNumber_reportsError() {
        List<String> errors = new List<String>();

        Assert.isNull(coercer().coerce('Amount', 'about ten', 'Row 8', errors));
        Assert.areEqual(1, errors.size());
        Assert.isTrue(errors[0].contains('is not a number'), errors[0]);
    }

    /**
     * Opportunity has no Long field, so ContentVersion's ContentSizeLong - a standard Long
     * on every org - stands in. A Long field is rounded to a whole number, as an Integer is.
     */
    @isTest
    static void coerce_longField_returnsRoundedLong() {
        List<String> errors = new List<String>();

        Object value = new DataImport.Coercer(ContentVersion.SObjectType)
            .coerce('ContentSizeLong', '1,234.5', 'Row 8', errors);

        Assert.isInstanceOfType(value, Long.class);
        Assert.areEqual(1235L, value);
        Assert.areEqual(0, errors.size());
    }

    /** Matched case-insensitively but stored in the picklist's own casing, or the platform rejects it. */
    @isTest
    static void coerce_picklistWrongCase_returnsPicklistCasing() {
        List<String> errors = new List<String>();
        String stageName = stage();

        Object value = coercer().coerce('StageName', stageName.toLowerCase(), 'Row 8', errors);

        Assert.areEqual(stageName, value);
        Assert.areEqual(0, errors.size());
    }

    /**
     * Caught here rather than at insert: the platform's own message names neither the
     * row nor the values allowed, which is what the recipient needs to fix the
     * spreadsheet.
     */
    @isTest
    static void coerce_valueOutsidePicklist_listsAllowedValues() {
        List<String> errors = new List<String>();

        Assert.isNull(coercer().coerce('StageName', 'Not A Stage', 'Row 8', errors));
        Assert.areEqual(1, errors.size());
        Assert.isTrue(errors[0].contains('allowed values'), errors[0]);
        Assert.isTrue(errors[0].contains(stage()), errors[0]);
    }

    /**
     * A picklist with no active values gives nothing to check against, so the cell goes
     * through as written and the platform has the last word. Order.Type ships with no
     * values; an org that has given it some cannot set this up, so the test stands down.
     */
    @isTest
    static void coerce_picklistWithNoValues_returnsTextAsWritten() {
        List<String> errors = new List<String>();
        DataImport.Coercer c = new DataImport.Coercer(Order.SObjectType);
        if (!c.allowedValues('Type').isEmpty()) {
            return;
        }

        Assert.areEqual('Anything', c.coerce('Type', ' Anything ', 'Row 8', errors));
        Assert.areEqual(0, errors.size());
    }

    @isTest
    static void coerce_yesNo_returnsBoolean() {
        List<String> errors = new List<String>();
        DataImport.Coercer c = coercer();

        Assert.areEqual(true, c.coerce('IsPrivate', 'Yes', 'Row 8', errors));
        Assert.areEqual(false, c.coerce('IsPrivate', 'No', 'Row 8', errors));
        Assert.areEqual(0, errors.size());
    }

    @isTest
    static void coerce_textOverFieldLength_reportsError() {
        List<String> errors = new List<String>();

        Assert.isNull(coercer().coerce('Name', 'x'.repeat(300), 'Row 8', errors));
        Assert.areEqual(1, errors.size());
        Assert.isTrue(errors[0].contains('longer than'), errors[0]);
    }

    /** An API name that is not on the object is a coding error, not something a recipient can fix. */
    @isTest
    static void coerce_unknownField_throws() {
        try {
            coercer().coerce('Not_A_Field__c', 'x', 'Row 8', new List<String>());
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(e.getMessage().contains('Not_A_Field__c'), e.getMessage());
        }
    }

    // ---------------- Coercer.assign ----------------

    /** A blank cell leaves the field alone, so an import can run over hand-entered records. */
    @isTest
    static void assign_blankCell_leavesFieldAlone() {
        Opportunity item = new Opportunity(Description = 'entered by hand');
        List<String> errors = new List<String>();

        coercer().assign(item, 'Description', '   ', 'Row 8', errors);

        Assert.areEqual('entered by hand', item.Description);
        Assert.areEqual(0, errors.size());
    }

    @isTest
    static void assign_validCell_setsCoercedValue() {
        Opportunity item = new Opportunity();
        List<String> errors = new List<String>();

        coercer().assign(item, 'Amount', '$1,000', 'Row 8', errors);

        Assert.areEqual(1000, item.Amount);
    }

    /** A bad cell must not also set a value - the record would go in half-wrong. */
    @isTest
    static void assign_badCell_leavesFieldNull() {
        Opportunity item = new Opportunity();
        List<String> errors = new List<String>();

        coercer().assign(item, 'CloseDate', 'someday', 'Row 8', errors);

        Assert.isNull(item.CloseDate);
        Assert.areEqual(1, errors.size());
    }

    // ---------------- parseDate / parseDecimal / errorMessage ----------------

    @isTest
    static void parseDate_unreadable_returnsNull() {
        Assert.isNull(DataImport.parseDate('13/45/2026'));
        Assert.isNull(DataImport.parseDate(''));
    }

    /** Date.valueOf throws on an ISO date the calendar does not have; that is a bad cell, not a crash. */
    @isTest
    static void parseDate_impossibleIsoDate_returnsNull() {
        Assert.isNull(DataImport.parseDate('2026-02-30'));
        Assert.isNull(DataImport.parseDate('2026-13-01'));
    }

    @isTest
    static void parseDecimal_unreadable_returnsNull() {
        Assert.isNull(DataImport.parseDecimal('$'));
        Assert.isNull(DataImport.parseDecimal(null));
    }

    /** Stripping symbols can leave digits that still are not one number, e.g. a version or a range. */
    @isTest
    static void parseDecimal_strayPointsOrDashes_returnsNull() {
        Assert.isNull(DataImport.parseDecimal('1.2.3'));
        Assert.isNull(DataImport.parseDecimal('10-20'));
    }

    @isTest
    static void errorMessage_underCap_listsEveryProblem() {
        List<String> errors = new List<String>();
        for (Integer i = 0; i < 3; i++) {
            errors.add('Row ' + i + ' broke');
        }

        String message = DataImport.errorMessage(errors);

        Assert.isTrue(message.contains('Row 0 broke'), message);
        Assert.isTrue(message.contains('Row 2 broke'), message);
    }

    /** A wholly mis-saved file produces one error per cell; the toast must stay readable. */
    @isTest
    static void errorMessage_overCap_summarisesRemainder() {
        List<String> errors = new List<String>();
        for (Integer i = 0; i < 25; i++) {
            errors.add('Row ' + i + ' broke');
        }

        String message = DataImport.errorMessage(errors);

        Assert.isTrue(message.contains('…and 15 more.'), message);
        Assert.isFalse(message.contains('Row 24 broke'), message);
    }

    // ---------------- read ----------------

    @isTest
    static void read_csvUpload_returnsParsedRows() {
        Id documentId = uploadFile('items.csv', 'a,b\n1,2');

        List<List<String>> rows = DataImport.read(documentId);

        Assert.areEqual(2, rows.size());
        Assert.areEqual(new List<String>{ '1', '2' }, rows[1]);
    }

    /** The workbooks are handed out as .xlsx; uploading one back unconverted is the likely slip. */
    @isTest
    static void read_nonCsvUpload_throws() {
        Id documentId = uploadFile('items.xlsx', 'binary-ish');

        try {
            DataImport.read(documentId);
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(e.getMessage().contains('.csv'), e.getMessage());
        }
    }

    @isTest
    static void read_missingDocument_throws() {
        try {
            DataImport.read('069000000000000AAA');
            Assert.fail('Expected a DataImportException.');
        } catch (DataImport.DataImportException e) {
            Assert.isTrue(e.getMessage().contains('could not be found'), e.getMessage());
        }
    }
}