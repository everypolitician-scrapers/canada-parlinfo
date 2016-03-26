#!/bin/env ruby
# encoding: utf-8

require 'colorize'
require 'combine_popolo_memberships'
require 'csv'
require 'nokogiri'
require 'open-uri'
require 'scraperwiki'

require 'pry'
require 'open-uri/cached'
OpenURI::Cache.cache_path = '.cache'

class String
  def tidy
    self.gsub(/[[:space:]]+/, ' ').strip
  end
end

def noko_for(url)
  Nokogiri::HTML(open(url).read)
end

def scrape_list(url)
  noko = noko_for(url)
  noko.xpath('//table[@id="ctl00_cphContent_ctl00_grdMembersList"]//tr[td]//td[1]/a').each do |a|
    data = { 
      id: CGI.parse(URI.parse(a.attr('href')).query)['Item'].first,
      name: a.text,
    }
    ScraperWiki.save_sqlite([:id], data, 'sources')
  end
end


class Person

  PERSON_URL = 'http://www.lop.parl.gc.ca/parlinfo/Files/Parliamentarian.aspx?Item=%s&Language=E'

  def initialize(h)
    @data = h
  end

  def member_data
    @md ||= Hash[ protected_methods.map { |m| [m, send(m)] } ]
  end

  def combined_memberships
    CombinePopoloMemberships.combine(term: elected, faction: group_memberships)
  end

  def data
    return unless elected.any?
    combined_memberships.map { |m| member_data.merge(m) }
  end

  protected

  def id
    @data[:id]
  end

  def name
    [given_name, family_name].join " "
  end

  def sort_name
    [family_name, given_name].join ", "
  end

  def family_name
    name_parts.first
  end

  def given_name
    name_parts.last
  end

  def birth_date
    date_str = noko.css('#ctl00_cphContent_DateOfBirthData').text.gsub('.','-')
    return date_str.empty? ? nil : Date.parse(date_str).to_s rescue nil
  end

  def death_date
    date_str = noko.css('#ctl00_cphContent_DeceasedDateData').text.gsub('.','-') 
    return date_str.empty? ? nil : Date.parse(date_str).to_s rescue nil
  end

  def birthplace
    noko.css('#ctl00_cphContent_PlaceOfBirthData').text
  end

  def image
    img = noko.css('#ctl00_cphContent_imgParliamentarianPicture/@src').text or return
    URI.join(source, img).to_s
  end

  def source
    PERSON_URL % id
  end

  private

  def noko
    @noko ||= Nokogiri::HTML(open(source).read)
  end

  def base_name
    noko.css('#ctl00_cphContent_lblTitle').text
  end

  def name_parts
    base_name.split(/\s*,\s*/, 2)
  end

  def commons
    noko.css('#ctl00_cphContent_ctl00_pnlSectionHouseOfCommons')
  end

 def elected
    commons.xpath('.//table[@id="ctl00_cphContent_ctl00_grdHouseOfCommons"]//tr[td]').map do |tr|
      td = tr.css('td')
      next if td.last.text == 'Defeated'
      raise "Unknown result: #{td.last.text}" unless td.last.text == 'Elected'
      date = Date.parse(td[2].css('span').find { |s| s.attr('id').include? 'Label' }.text.tidy.gsub('.','-')).to_s
      term = term_for(date) or next
      {
        id: term[:id],
        constituency: td[0].css('span').find { |s| s.attr('id').include? 'Label' }.text.tidy,
        start_date: date,
        end_date: term[:end_date], # no record of people leaving early?
      }
    end.compact
  end

  def group_memberships
    noko.xpath('.//table[@id="ctl00_cphContent_ctl00_grdCaucus"]//tr[td]').map do |tr|
      td = tr.css('td')
      start_date, end_date = td.last.text.tidy.split(' - ').map { |d| d.gsub('.','-') }
      {
        id: td.first.text.tidy,
        start_date: start_date,
        end_date: end_date,
      }
    end
  end

  def minister
    #TODO bd9df755-dfce-42dc-9ebb-55306d610edc
  end
    
  TERM_SOURCE = 'https://raw.githubusercontent.com/everypolitician/everypolitician-data/master/data/Canada/Commons/sources/manual/terms.csv'
  def all_terms
    @_terms = CSV.parse(open(TERM_SOURCE).read, headers: true, header_converters: :symbol).sort_by { |t| t[:start_date] }.reverse
  end

  def term_for(date)
    # the date is usually between terms (a general election), but
    # sometimes mid-term (by-election)
    all_terms.partition { |t| t[:end_date].to_s > date }.first.last
  end
end


def scrape_person(id)
  p = Person.new(id: id)
  data = p.data or return
  ScraperWiki.save_sqlite([:id, :term, :start_date], data) 
end

res = ScraperWiki.select('DISTINCT(sources.id) FROM sources LEFT JOIN data ON sources.id = data.id WHERE data.name IS NULL') rescue nil

if res
  warn "#{res.count} to fetch"
  res.each_with_index do |r, i| 
    warn i if (i % 10).zero?
    scrape_person r['id'] 
  end
else
  scrape_list('http://www.lop.parl.gc.ca/parlinfo/Lists/Members.aspx?New=False&Current=False')
  warn "List updated"
end

