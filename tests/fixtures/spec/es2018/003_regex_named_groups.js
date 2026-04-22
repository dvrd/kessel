const re = /(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})/;
const match = re.exec("2025-01-15");
const { year, month, day } = match.groups;
