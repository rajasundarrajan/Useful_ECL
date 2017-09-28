IMPORT Std;

#WORKUNIT('name', 'File Part Analyzer');
#OPTION('pickBestEngine', FALSE);

// ESP (ECL Watch) information for the cluster you will be inspecting; this is
// needed even if you are analyzing data on the cluster that will be running
// this job, as there is no way to determine an ESP URL from within ECL
ESP_SCHEME := 'http';
ESP_IP := '127.0.0.1';
ESP_PORT := '8010';
ESP_USER := '';
ESP_USER_PW := '';

// Dali IP used to extract the list of logical files to analyze; defaults
// to the Dali that is used by the cluster running this job; unless you
// are analyzing data on a cluster that is different from the cluster running
// this job, you can leave this parameter as-is
DALI_IP := Std.System.Thorlib.DaliServer();

// File name pattern to use when searching for files to analyze; use '*' to
// analyze all Thor files; the '*' wildcard matches zero or more characters,
// the '?' wildcard matches one character; note that you can supply an exact
// full logical filename to analyze just one file
FILE_NAME_PATTERN := '*';

// All output files will be created with OUTPUT_FILE_PREFIX as a prefix
OUTPUT_FILE_PREFIX := 'file_part_analyzer';

#IF(OUTPUT_FILE_PREFIX = '')
    #ERROR('Attribute OUTPUT_FILE_PREFIX cannot be an empty string')
#END

//------------------------------------------------------------------------------

OUTPUT(FILE_NAME_PATTERN, NAMED('file_name_pattern'));
OUTPUT(ESP_IP, NAMED('esp_ip_address'));

// Get a list of all logical files on the cluster
filenameList := DISTRIBUTE(NOTHOR(Std.File.LogicalFileList(namepattern := FILE_NAME_PATTERN, foreigndali := DALI_IP)));

// Build up a full URL for the ESP service (same as ECL Watch)
fullUserInfo := MAP
    (
        ESP_USER != '' AND ESP_USER_PW != ''    =>  ESP_USER + ':' + ESP_USER_PW + '@',
        ESP_USER != ''                          =>  ESP_USER + '@',
        ''
    );

serviceURL := ESP_SCHEME + '://' + TRIM(fullUserInfo, LEFT, RIGHT) + ESP_IP + ':' + ESP_PORT;

//------------------------------------------------------------------------------
// Get topology information so we know what names are used for Thor clusters
//------------------------------------------------------------------------------
ClusterNameRec := RECORD
    STRING      cluster_name    {XPATH('Name')};
END;

TopologyRec := RECORD
    STRING                      cluster_type {XPATH('Type')};
    DATASET(ClusterNameRec)     clusters    {XPATH('TpClusters/TpCluster')};
END;

rawTopologyInfo := SOAPCALL
    (
        serviceURL + '/WsTopology?ver_=1.25', // Verified with platform 6.2.20-1
        'TpTargetClusterQuery',
        {
            STRING  pType {XPATH('Type')} := ''
        },
        DATASET(TopologyRec),
        XPATH('TpTargetClusterQueryResponse/TpTargetClusters/TpTargetCluster'),
        TRIM
    );

topologyInfo := PROJECT
    (
        rawTopologyInfo(COUNT(clusters) <= 1),
        TRANSFORM
            (
                {
                    STRING      cluster_type,
                    STRING      cluster_name
                },

                theName := LEFT.clusters[1].cluster_name;

                SELF.cluster_type := IF(LEFT.cluster_type = 'ThorCluster', 'thor', SKIP),
                SELF.cluster_name := IF(theName != '', theName, SELF.cluster_type)
            )
    );

//------------------------------------------------------------------------------
// Get file part information for all files that matched the file name pattern
//------------------------------------------------------------------------------
RawFilePartRec := RECORD
    UNSIGNED1                   part_id             {XPATH('Id')};
    UNSIGNED1                   copy_num            {XPATH('Copy')};
    STRING                      ip_address          {XPATH('Ip')};
    STRING                      part_size_bytes     {XPATH('Partsize')};
END;

RawClusterInfoRec := RECORD
    STRING                      cluster_name        {XPATH('Cluster')};
    DATASET(RawFilePartRec)     file_parts          {XPATH('DFUFileParts/DFUPart')};
END;

RawResultRec := RECORD
    STRING                      file_name           {XPATH('Name')};
    STRING                      owner               {XPATH('Owner')};
    STRING                      file_size_bytes     {XPATH('Filesize')};
    STRING                      record_size_bytes   {XPATH('Recordsize')};
    STRING                      record_cnt          {XPATH('RecordCount')};
    DATASET(RawClusterInfoRec)  clusterInfo         {XPATH('DFUFilePartsOnClusters[1]/DFUFilePartsOnCluster')};
END;

DFUInfoParamRec := RECORD
    STRING  pfile_name {XPATH('Name')};
END;

dfuInfoRawResults := SOAPCALL
    (
        filenameList,
        serviceURL + '/WsDFU?ver_=1.34', // Verified with platform 6.2.20-1
        'DFUInfo',
        DFUInfoParamRec,
        TRANSFORM
            (
                DFUInfoParamRec,
                SELF.pfile_name := LEFT.name
            ),
        DATASET(RawResultRec),
        XPATH('DFUInfoResponse/FileDetail'),
        TRIM
    );

OUTPUT(COUNT(dfuInfoRawResults), NAMED('files_found_cnt'));

OUTPUT(dfuInfoRawResults,,'~' + OUTPUT_FILE_PREFIX + '::01_raw_results',NOXPATH,COMPRESSED,OVERWRITE);

//------------------------------------------------------------------------------
// Normalize one level, hoisting the cluster name up to the file_name level
//------------------------------------------------------------------------------
DFUResultRec2 := RECORD
    STRING                      file_name;
    STRING                      owner;
    UNSIGNED8                   file_size_bytes;
    UNSIGNED8                   record_size_bytes;
    UNSIGNED8                   record_cnt;
    STRING                      cluster_name;
    DATASET(RawFilePartRec)     file_parts;
END;

normalizedDFUInfoResults := NORMALIZE
    (
        DISTRIBUTE(dfuInfoRawResults),
        LEFT.clusterInfo,
        TRANSFORM
            (
                DFUResultRec2,
                SELF.cluster_name := RIGHT.cluster_name,
                SELF.file_parts := RIGHT.file_parts,
                SELF.file_size_bytes := (UNSIGNED8)Std.Str.FilterOut(LEFT.file_size_bytes, ','),
                SELF.record_size_bytes := (UNSIGNED8)Std.Str.FilterOut(LEFT.record_size_bytes, ','),
                SELF.record_cnt := (UNSIGNED8)Std.Str.FilterOut(LEFT.record_cnt, ','),
                SELF := LEFT
            )
    );

//------------------------------------------------------------------------------
// Filter so that only file_names belonging to a Thor cluster remain
//------------------------------------------------------------------------------
onlyThorData := JOIN
    (
        normalizedDFUInfoResults,
        topologyInfo,
        LEFT.cluster_name = RIGHT.cluster_name,
        TRANSFORM(LEFT),
        LOOKUP
    );

OUTPUT(COUNT(onlyThorData), NAMED('thor_files_found_cnt'));

//------------------------------------------------------------------------------
// Normalize file part information; we'll wind up with one record per file
// part
//------------------------------------------------------------------------------
FilePartRec := RECORD
    UNSIGNED1                   part_id;
    UNSIGNED8                   part_size_bytes;
    DECIMAL9_2                  part_skew_pct;
END;

DFUResultRec3 := RECORD
    STRING                      file_name;
    STRING                      owner;
    UNSIGNED8                   file_size_bytes;
    UNSIGNED8                   record_size_bytes;
    UNSIGNED8                   record_cnt;
    STRING                      cluster_name;
    FilePartRec;
END;

flattenedResults := NORMALIZE
    (
        onlyThorData,
        LEFT.file_parts(copy_num = 1), // Look at only the first copy of a file
        TRANSFORM
            (
                DFUResultRec3,

                REAL idealpart_size_bytes := LEFT.file_size_bytes / Std.System.Thorlib.Nodes();

                SELF.part_size_bytes := (UNSIGNED8)Std.Str.FilterOut(RIGHT.part_size_bytes, ','),
                SELF.part_skew_pct := ((REAL)SELF.part_size_bytes - idealpart_size_bytes) / idealpart_size_bytes * 100,
                SELF := RIGHT,
                SELF := LEFT
            )
    );

OUTPUT(flattenedResults,,'~' + OUTPUT_FILE_PREFIX + '::02_normalized_results',NOXPATH,COMPRESSED,OVERWRITE);

//------------------------------------------------------------------------------
// Simple analysis of the flattened results
//------------------------------------------------------------------------------
analysis := TABLE
    (
        flattenedResults,
        {
            file_name,
            owner,
            cluster_name,
            file_size_bytes,
            record_cnt,
            UNSIGNED2   file_part_cnt := COUNT(GROUP),
            DECIMAL9_2  min_part_skew_pct := MIN(GROUP, part_skew_pct),
            DECIMAL9_2  max_part_skew_pct := MAX(GROUP, part_skew_pct),
            UNSIGNED2   num_high_skew := SUM(GROUP, IF(part_skew_pct >= 200, 1, 0)),
            UNSIGNED2   num_low_skew := SUM(GROUP, IF(part_skew_pct <= -70, 1, 0)),
            UNSIGNED2   num_index_parts := SUM(GROUP, IF(part_size_bytes = 32768, 1, 0)) // Kind of a hack
        },
        file_name, owner, cluster_name, file_size_bytes, record_cnt,
        LOCAL
    );

flaggedAnalysis := PROJECT
    (
        analysis,
        TRANSFORM
            (
                {
                    BOOLEAN     flagged,
                    RECORDOF(LEFT)
                },
                SELF.flagged := MAP
                    (
                        LEFT.num_index_parts = 1        =>  FALSE, // Don't flag index files stored on Thor
                        LEFT.record_cnt < 250000        =>  FALSE,
                        LEFT.max_part_skew_pct >= 300   =>  TRUE,
                        LEFT.num_high_skew > 1          =>  TRUE,
                        LEFT.num_low_skew > 1           =>  TRUE,
                        LEFT.min_part_skew_pct = -100   =>  TRUE,
                        FALSE
                    ),
                SELF := LEFT
            )
    );

OUTPUT(COUNT(flaggedAnalysis(flagged)), NAMED('flagged_file_cnt'));

//------------------------------------------------------------------------------
// Attach detailed part information to each file
//------------------------------------------------------------------------------
summary := DENORMALIZE
    (
        flaggedAnalysis,
        flattenedResults,
        LEFT.file_name = RIGHT.file_name
            AND LEFT.cluster_name = RIGHT.cluster_name,
        GROUP,
        TRANSFORM
            (
                {
                    RECORDOF(LEFT),
                    DATASET(FilePartRec)    partInfo
                },
                SELF.partInfo := PROJECT(ROWS(RIGHT), TRANSFORM(FilePartRec, SELF := LEFT)),
                SELF := LEFT
            )
    );

//------------------------------------------------------------------------------
// Output final results
//------------------------------------------------------------------------------
sortedSummary := SORT(summary, -max_part_skew_pct, min_part_skew_pct);

OUTPUT(sortedSummary,,'~' + OUTPUT_FILE_PREFIX + '::03_summary_all_thor_files',NOXPATH,COMPRESSED,OVERWRITE);
OUTPUT(sortedSummary(flagged),,'~' + OUTPUT_FILE_PREFIX + '::04_summary_flagged_thor_files',NOXPATH,COMPRESSED,OVERWRITE);