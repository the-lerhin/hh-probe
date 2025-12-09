# hh.models.psm1 — Strongly-typed models for canonical vacancies
#Requires -Version 7.0

<#
.SYNOPSIS
Ensures canonical model types are available in the runspace.

.DESCRIPTION
Defines the typed classes via Add-Type when they are not already present. This keeps
canonical pipeline objects strongly-typed across Pester runspaces and module imports.
#>
function Ensure-HHModelTypes {
  param()

  $typesReady = $false
  try { $null = [CanonicalVacancy]; $typesReady = $true } catch { $typesReady = $false }

  if (-not $typesReady) {
    $typeDef = @"
public class SalaryInfo {
  public string text { get; set; } = string.Empty;
  public double from { get; set; } = 0;
  public double to { get; set; } = 0;
  public string currency { get; set; } = string.Empty;
  public bool gross { get; set; } = false;
  public string symbol { get; set; } = string.Empty;
  public string frequency { get; set; } = string.Empty;
  public string mode { get; set; } = string.Empty;
  private double _upperCap = 0;
  public double upper_cap { get { return _upperCap; } set { _upperCap = value; } }
  public double UpperCap { get { return _upperCap; } set { _upperCap = value; } }
  public SalaryInfo() { }
}

public class EmployerInfo {
  public string id { get; set; } = string.Empty;
  public string name { get; set; } = string.Empty;
  public double rating { get; set; } = 0;
  public int open { get; set; } = 0;
  public string size { get; set; } = string.Empty;
  public string industry { get; set; } = string.Empty;
  public string logo { get; set; } = string.Empty;
  public string LogoUrl { get { return logo; } set { logo = value; } }
  public string Url { get; set; } = string.Empty;
  public bool Trusted { get; set; } = false;
  public EmployerInfo() { }
}

public class SummaryInfo {
  public string text { get; set; } = string.Empty;
  public string source { get; set; } = string.Empty;
  public string lang { get; set; } = string.Empty;
  public string model { get; set; } = string.Empty;
  public string RemoteText { get; set; } = string.Empty;
  public SummaryInfo() { }
}

public class PicksInfo {
  public bool IsEditorsChoice { get; set; } = false;
  public bool IsLucky { get; set; } = false;
  public bool IsWorst { get; set; } = false;
  public string EditorsWhy { get; set; } = string.Empty;
  public string LuckyWhy { get; set; } = string.Empty;
  public string WorstWhy { get; set; } = string.Empty;
  public string Lang { get; set; } = string.Empty;
  public System.Nullable<System.DateTime> GeneratedAtUtc { get; set; } = System.DateTime.UtcNow;
  public PicksInfo() { }
}

public class ScoreInfo {
  public double cv { get; set; } = 0;
  public double skills { get; set; } = 0;
  public double salary { get; set; } = 0;
  public double recency { get; set; } = 0;
  public double location { get; set; } = 0;
  public double remote { get; set; } = 0;
  public double leadership { get; set; } = 0;
  public double english { get; set; } = 0;
  public double employerSig { get; set; } = 0;
  public double employer { get; set; } = 0;
  public double badges { get; set; } = 0;
  public double seniority { get; set; } = 0;
  public double local_llm { get; set; } = 0;
  public double duplicates_penalty { get; set; } = 0;
  public double culture_penalty { get; set; } = 0;
  public double rating_bonus { get; set; } = 0;
  public double total { get; set; } = 0;
  public ScoreInfo() { }
}

public class PenaltyInfo {
  public double duplicate { get; set; } = 0;
  public double culture { get; set; } = 0;
  public PenaltyInfo() { }
}

public class SkillsInfo {
  public double Score { get; set; } = 0;
  public string[] MatchedVacancy { get; set; } = System.Array.Empty<string>();
  public string[] InCV { get; set; } = System.Array.Empty<string>();
  public string[] MissingForCV { get; set; } = System.Array.Empty<string>();
  public SkillsInfo() { }
}

public class BadgeInfo {
  public string kind { get; set; } = string.Empty;
  public string label { get; set; } = string.Empty;
  public BadgeInfo() { }
}

public class ExperienceInfo {
  public string id { get; set; } = string.Empty;
  public string name { get; set; } = string.Empty;
  public ExperienceInfo() { }
}

public class VacancyRankingMeta {
  public double BaselineScore { get; set; } = 0;
  public double RemoteFitScore { get; set; } = 0;
  public double FinalScore { get; set; } = 0;
  public string SummarySource { get; set; } = string.Empty;
  public double PremiumScore { get; set; } = 0;
  public string PremiumSummary { get; set; } = string.Empty;
  public VacancyRankingMeta() { }
}

public class MetaInfo {
  public string Source { get; set; } = string.Empty;
  public string plain_desc { get; set; } = string.Empty;
  public ScoreInfo scores { get; set; } = new ScoreInfo();
  public PenaltyInfo penalties { get; set; } = new PenaltyInfo();
  public SummaryInfo summary { get; set; } = new SummaryInfo();
  public SummaryInfo llm_summary { get; set; } = new SummaryInfo();
  public string summary_source { get; set; } = string.Empty;
  public string summary_model { get; set; } = string.Empty;
  public double local_llm_relevance { get; set; } = 0;
  public string search_stage { get; set; } = string.Empty;
  public object Raw { get; set; }
  public object local_summary { get; set; }
  public VacancyRankingMeta ranking { get; set; } = new VacancyRankingMeta();
  
  public MetaInfo() {
    if (scores == null) { scores = new ScoreInfo(); }
    if (penalties == null) { penalties = new PenaltyInfo(); }
    if (summary == null) { summary = new SummaryInfo(); }
    if (llm_summary == null) { llm_summary = new SummaryInfo(); }
    if (ranking == null) { ranking = new VacancyRankingMeta(); }
  }
}

public class CanonicalVacancy {
  // Legacy fields (deprecated; kept for backward compatibility; candidate for .tmp)
  public string id { get; set; } = string.Empty;
  public string title { get; set; } = string.Empty;
  public string link { get; set; } = string.Empty;
  public string city { get; set; } = string.Empty;
  public string AreaId { get; set; } = string.Empty;
  public string AreaName { get; set; } = string.Empty;
  public string country { get; set; } = string.Empty;
  public string age_text { get; set; } = string.Empty;
  public string description { get; set; } = string.Empty;
  public System.Nullable<System.DateTime> published_at { get; set; } = System.DateTime.UtcNow;
  public EmployerInfo employer { get; set; } = new EmployerInfo();
  public SalaryInfo salary { get; set; } = new SalaryInfo();
  public ExperienceInfo Experience { get; set; } = new ExperienceInfo();
  public MetaInfo meta { get; set; } = new MetaInfo();
  public PicksInfo picks { get; set; } = new PicksInfo();
  public SkillsInfo skills { get; set; } = new SkillsInfo();
  public double score { get; set; } = 0;
  public BadgeInfo[] badges { get; set; } = System.Array.Empty<BadgeInfo>();
  public string badges_text { get; set; } = string.Empty;
  private string[] _skillsMatched = System.Array.Empty<string>();

  // CanonicalVacancy v2 fields
  public string Url { get; set; } = string.Empty;
  public string SearchStage { get; set; } = string.Empty;
  public string[] SearchTiers { get; set; } = System.Array.Empty<string>();
  public double SalaryTop { get; set; } = 0;
  public string SalaryCurrency { get; set; } = string.Empty;
  public bool IsNonRuCountry { get; set; } = false;
  public bool IsRemote { get; set; } = false;
  public bool IsRelocation { get; set; } = false;
  public string EmployerId { get; set; } = string.Empty;
  public string EmployerName { get; set; } = string.Empty;
  public string EmployerLogoUrl { get; set; } = string.Empty;
  public double EmployerRating { get; set; } = 0;
  public int EmployerOpenVacancies { get; set; } = 0;
  public string EmployerIndustryShort { get; set; } = string.Empty;
  public bool EmployerAccreditedIT { get; set; } = false;
  public System.Nullable<System.DateTime> PublishedAtUtc { get; set; } = System.DateTime.UtcNow;
  public System.Nullable<System.DateTime> PublishedAt { get { return PublishedAtUtc; } set { PublishedAtUtc = value; } }
  public string AgeText { get; set; } = string.Empty;
  public string AgeTooltip { get; set; } = string.Empty;
  public string ScoreTip { get; set; } = string.Empty;
  public bool IsEditorsChoice { get; set; } = false;
  public bool IsLucky { get; set; } = false;
  public bool IsWorst { get; set; } = false;
  public string EditorsWhy { get; set; } = string.Empty;
  public string LuckyWhy { get; set; } = string.Empty;
  public string WorstWhy { get; set; } = string.Empty;
  public string Summary { get; set; } = string.Empty;
  public string[] SkillsMatched { 
    get { return _skillsMatched ?? System.Array.Empty<string>(); }
    set { _skillsMatched = value ?? System.Array.Empty<string>(); }
  }
  public string[] KeySkills { get; set; } = System.Array.Empty<string>();

  public CanonicalVacancy() {
    employer = employer ?? new EmployerInfo();
    salary = salary ?? new SalaryInfo();
    Experience = Experience ?? new ExperienceInfo();
    meta = meta ?? new MetaInfo();
    picks = picks ?? new PicksInfo();
    skills = skills ?? new SkillsInfo();
    badges = System.Array.Empty<BadgeInfo>();
    badges_text = string.Empty;
    _skillsMatched = _skillsMatched ?? System.Array.Empty<string>();
    SkillsMatched = System.Array.Empty<string>();
  }
}
"@
    Add-Type -TypeDefinition $typeDef -Language CSharp -ErrorAction Stop | Out-Null
  }

  try { $null = [CanonicalVacancy] } catch { throw "Typed models not available: $($_.Exception.Message)" }

  $script:CanonicalVacancy = [CanonicalVacancy]
  $script:SalaryInfo = [SalaryInfo]
  $script:EmployerInfo = [EmployerInfo]
  $script:ExperienceInfo = [ExperienceInfo]
  $script:SummaryInfo = [SummaryInfo]
  $script:PicksInfo = [PicksInfo]
  $script:MetaInfo = [MetaInfo]
  $script:ScoreInfo = [ScoreInfo]
  $script:PenaltyInfo = [PenaltyInfo]
  $script:SkillsInfo = [SkillsInfo]
  $script:BadgeInfo = [BadgeInfo]
  $script:VacancyRankingMeta = [VacancyRankingMeta]
}

function New-CanonicalVacancy {
  Ensure-HHModelTypes
  return New-Object CanonicalVacancy
}

Export-ModuleMember -Function Ensure-HHModelTypes, New-CanonicalVacancy
